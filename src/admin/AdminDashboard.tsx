import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import type { EventlyProfile } from "../lib/supabase";
import { eventlyFunctionBaseUrl, isMissingSupabaseRpc, signOutUser, supabase } from "../lib/supabase";
import { MessagingInbox } from "../messaging/MessagingViews";

type Row = Record<string, unknown>;
type ScheduleResourceOption = { label: string; location: string; type: string; value: string };
type LoadState = "loading" | "ready" | "error";
type BookingStatus = "pending" | "confirmed" | "completed" | "cancelled";

const sections = [
  ["dashboard", "Dashboard", "grid"],
  ["reservations", "Reservations", "calendar"],
  ["staff-approvals", "Staff Approval Queue", "check"],
  ["orders", "Orders", "list"],
  ["customers", "Customers", "users"],
  ["packages", "Packages & Services", "box"],
  ["catering-menu", "Catering Menu", "list"],
  ["addons", "Add-ons", "plus"],
  ["payments", "Payments", "card"],
  ["reviews", "Reviews", "star"],
  ["staff", "Staff Management", "users"],
  ["reports", "Reports & Analytics", "chart"],
  ["notifications", "Notifications", "bell"],
  ["messages", "Messages", "message"],
  ["activity-logs", "Activity Logs", "clock"],
  ["settings", "Settings", "settings"],
] as const;

const cateringMenuCategories = ["Beef", "Pork", "Chicken", "Seafood", "Vegetable", "Pancit", "Dessert", "Drinks"];

const tableBySection: Record<string, string> = {
  reservations: "reservations",
  orders: "orders",
  customers: "profiles",
  packages: "packages",
  payments: "payments",
  reviews: "reviews",
  notifications: "notifications",
  "activity-logs": "admin_activity_logs",
  "catering-menu": "catering_menu_items",
  addons: "addons",
};

const columnsBySection: Record<string, { label: string; keys: string[] }[]> = {
  reservations: [
    { label: "Reservation Code", keys: ["reservation_code", "code", "id"] },
    { label: "Customer", keys: ["_customer_name", "customer_name", "full_name", "customer_id", "user_id"] },
    { label: "Service", keys: ["service", "service_type", "service_category"] },
    { label: "Package", keys: ["package_name", "package_id"] },
    { label: "Variant", keys: ["package_variant", "package_variant_id"] },
    { label: "Reservation Date", keys: ["reservation_date", "event_date", "date"] },
    { label: "Start", keys: ["start_time"] },
    { label: "End", keys: ["end_time"] },
    { label: "Guests", keys: ["guest_count", "guests", "number_of_guests"] },
    { label: "Total", keys: ["total_amount", "total", "amount"] },
    { label: "Payment", keys: ["payment_status"] },
    { label: "Status", keys: ["status"] },
    { label: "Submitted", keys: ["created_at"] },
  ],
  orders: [
    { label: "Order Code", keys: ["order_code", "code", "id"] },
    { label: "Customer", keys: ["_customer_name", "customer_name", "customer_id", "user_id"] },
    { label: "Reservation", keys: ["_reservation_code", "reservation_code", "reservation_id"] },
    { label: "Order Type / Items", keys: ["_food_summary", "package_name", "package_id"] },
    { label: "Fulfillment", keys: ["fulfillment_method"] },
    { label: "Time", keys: ["requested_time"] },
    { label: "Event Date", keys: ["event_date", "reservation_date", "created_at"] },
    { label: "Guests", keys: ["guest_count", "guests"] },
    { label: "Total", keys: ["total_amount", "total", "amount"] },
    { label: "Payment", keys: ["payment_status"] },
    { label: "Status", keys: ["order_status", "status"] },
  ],
  customers: [
    { label: "Full Name", keys: ["full_name"] },
    { label: "Email", keys: ["email"] },
    { label: "Mobile", keys: ["mobile_number"] },
    { label: "Reservations", keys: ["reservation_count"] },
    { label: "Recent Booking", keys: ["recent_booking"] },
    { label: "Recent Activity", keys: ["recent_booking_date"] },
    { label: "Registered", keys: ["created_at"] },
  ],
  packages: [
    { label: "Package", keys: ["name", "package_name", "title"] },
    { label: "Service", keys: ["service", "service_type", "category"] },
    { label: "Price", keys: ["price", "base_price", "amount"] },
    { label: "Deposit %", keys: ["deposit_percentage"] },
    { label: "Capacity", keys: ["guest_capacity", "capacity", "max_guests"] },
    { label: "Status", keys: ["is_active", "active", "status"] },
    { label: "Updated", keys: ["updated_at", "created_at"] },
  ],
  payments: [
    { label: "Reservation Code", keys: ["_reservation_code", "reservation_id"] },
    { label: "Customer", keys: ["_customer_name", "customer_name", "customer_id", "user_id"] },
    { label: "Payment Reference", keys: ["reference_number", "payment_reference", "reference", "id"] },
    { label: "Amount", keys: ["amount", "payment_amount"] },
    { label: "Method", keys: ["payment_method", "method"] },
    { label: "Status", keys: ["verification_status", "payment_status", "status"] },
    { label: "Receipt", keys: ["_receipt_status"] },
    { label: "Payment Date", keys: ["submitted_at", "created_at"] },
  ],
  reviews: [
    { label: "Customer", keys: ["customer_name", "customer_id", "user_id"] },
    { label: "Rating", keys: ["rating"] },
    { label: "Review", keys: ["review_text", "comment", "content"] },
    { label: "Reservation", keys: ["reservation_id"] },
    { label: "Published", keys: ["is_published"] },
    { label: "Submitted", keys: ["created_at"] },
  ],
  notifications: [
    { label: "Recipient", keys: ["user_id", "profile_id"] },
    { label: "Title", keys: ["title", "subject", "type"] },
    { label: "Message", keys: ["message", "body", "content"] },
    { label: "Read", keys: ["is_read", "read_at"] },
    { label: "Created", keys: ["created_at"] },
  ],
  "activity-logs": [
    { label: "Administrator", keys: ["admin_name", "admin_id", "user_id"] },
    { label: "Action", keys: ["action"] },
    { label: "Description", keys: ["description", "details"] },
    { label: "Entity Type", keys: ["entity_type"] },
    { label: "Entity ID", keys: ["entity_id"] },
    { label: "Timestamp", keys: ["created_at", "timestamp"] },
  ],
  "catering-menu": [
    { label: "Menu Item", keys: ["name"] },
    { label: "Category", keys: ["category"] },
    { label: "Price / Tray", keys: ["tray_price"] },
    { label: "Available", keys: ["is_available", "available"] },
    { label: "Active", keys: ["is_active", "active"] },
    { label: "Updated", keys: ["updated_at", "created_at"] },
  ],
  addons: [
    { label: "Add-on", keys: ["name"] },
    { label: "Compatible Services", keys: ["compatible_services", "service"] },
    { label: "Price", keys: ["price", "amount"] },
    { label: "Available", keys: ["is_active", "available"] },
    { label: "Updated", keys: ["updated_at", "created_at"] },
  ],
};

const navigationGroups = [
  { label: "Dashboard", paths: ["dashboard", "notifications"] },
  { label: "Booking Management", paths: ["staff-approvals", "reservations", "orders"] },
  { label: "Business Management", paths: ["packages", "catering-menu", "addons", "customers", "staff"] },
  { label: "Finance & Insights", paths: ["payments", "reports", "reviews"] },
  { label: "Communication", paths: ["messages"] },
  { label: "System", paths: ["activity-logs", "settings"] },
];

const pageDescriptions: Record<string, string> = {
  dashboard: "Monitor reservations, payments, and business activity in one place.",
  reservations: "Review booking details, payment progress, and reservation status.",
  "staff-approvals": "Review staff recommendations and coordinate final booking decisions.",
  orders: "Track fulfillment and keep every Evently order moving.",
  customers: "Find customer profiles and review account information.",
  packages: "Manage Catering, Resort, and Staycation offerings.",
  "catering-menu": "Organize menu items by category and availability.",
  addons: "Review optional services offered during the booking journey.",
  payments: "Prioritize submitted payments and verification status.",
  reviews: "Review customer feedback and publication status.",
  staff: "Invite staff and manage operational permissions.",
  reports: "Export and analyze RLS-permitted operational records.",
  notifications: "Review customer-facing and operational notifications.",
  messages: "Browse fictional customer conversations in the Evently Demo Chat inbox.",
  "activity-logs": "Trace important administrative activity.",
  settings: "Manage account security and supported business preferences.",
};

const money = new Intl.NumberFormat("en-PH", { style: "currency", currency: "PHP" });
const date = new Intl.DateTimeFormat("en-PH", { dateStyle: "medium" });

async function loadAdminRows(section: string, table: string) {
  if (section === "customers") {
    const [profiles, reservations] = await Promise.all([
      supabase.from("profiles").select("*").limit(500),
      supabase.from("reservations").select("*").limit(1000),
    ]);
    const failure = profiles.error ?? reservations.error;
    if (failure) throw failure;
    return ((profiles.data ?? []) as Row[]).map((profile) => {
      const customerReservations = ((reservations.data ?? []) as Row[])
        .filter((reservation) => String(reservation.customer_id) === String(profile.id))
        .sort((a, b) => String(first(b, ["created_at"]) ?? "").localeCompare(String(first(a, ["created_at"]) ?? "")));
      return {
        ...profile,
        reservation_count: customerReservations.length,
        recent_booking: first(customerReservations[0] ?? {}, ["reservation_code"]),
        recent_booking_date: first(customerReservations[0] ?? {}, ["reservation_date"]),
      };
    });
  }
  if (!["reservations", "orders", "payments"].includes(section)) {
    const result = await supabase.from(table).select("*").limit(500);
    if (result.error) throw result.error;
    return (result.data ?? []) as Row[];
  }

  const tableNames = section === "payments"
    ? ["payments", "reservations", "profiles"] as const
    : section === "orders"
      ? ["orders", "reservations", "profiles", "evently_food_order_items"] as const
      : ["reservations", "profiles", "evently_booking_recommendations", "evently_catering_change_requests", "packages", "package_variants"] as const;
  const results = await Promise.all(tableNames.map((name) => supabase.from(name).select("*").limit(500)));
  const optionalCateringRequestIndex = section === "reservations"
    ? tableNames.findIndex((name) => String(name) === "evently_catering_change_requests") : -1;
  const failure = results.find((result, index) => result.error && index !== optionalCateringRequestIndex)?.error;
  if (failure) throw failure;
  const byTable = Object.fromEntries(tableNames.map((name, index) => [name, (results[index].error ? [] : results[index].data ?? []) as Row[]]));
  const profiles = byTable.profiles ?? [];
  const reservations = byTable.reservations ?? [];
  const profileName = (customerId: unknown) => first(
    profiles.find((profile) => String(profile.id) === String(customerId)) ?? {},
    ["full_name", "email"],
  );

  if (section === "reservations") {
    const recommendations = (byTable.evently_booking_recommendations ?? []) as Row[];
    const cateringRequests = (byTable.evently_catering_change_requests ?? []) as Row[];
    const packages = (byTable.packages ?? []) as Row[];
    const variants = (byTable.package_variants ?? []) as Row[];
    return (reservations.map((reservation) => {
      const recommendation = recommendations
        .filter((item) => String(item.reservation_id) === String(reservation.id))
        .sort((left, right) => String(right.created_at ?? "").localeCompare(String(left.created_at ?? "")))[0] ?? null;
      const packageRow = packages.find((item) => String(item.id) === String(reservation.package_id));
      const variantRow = variants.find((item) => String(item.id) === String(reservation.package_variant_id));
      return {
        ...reservation,
        package_name: first(reservation, ["package_name"]) ?? first(packageRow ?? {}, ["name"]),
        package_category: first(reservation, ["package_category"]) ?? first(packageRow ?? {}, ["package_category"]),
        resource_key: first(reservation, ["resource_key"]) ?? first(variantRow ?? {}, ["resource_key"]) ?? first(packageRow ?? {}, ["resource_key"]),
        resource_mode: first(reservation, ["resource_mode"]) ?? first(packageRow ?? {}, ["resource_mode"]),
        schedule_mode: first(reservation, ["schedule_mode"]) ?? first(variantRow ?? {}, ["schedule_mode"]) ?? first(packageRow ?? {}, ["schedule_mode"]),
        _customer_name: first(reservation, ["customer_name"]) ?? profileName(reservation.customer_id),
        _latest_staff_recommendation: recommendation ? {
          ...recommendation,
          staff_name: profileName(recommendation.staff_id),
        } : null,
        _catering_change_requests: cateringRequests
          .filter((item) => String(item.reservation_id) === String(reservation.id))
          .sort((left, right) => String(right.requested_at ?? "").localeCompare(String(left.requested_at ?? ""))),
      };
    }) as Row[]).sort((left, right) => {
      const leftPending = String(left.status ?? "").toLowerCase() === "pending" ? 0 : 1;
      const rightPending = String(right.status ?? "").toLowerCase() === "pending" ? 0 : 1;
      return leftPending - rightPending;
    });
  }
  if (section === "payments") {
    return (byTable.payments ?? []).map((payment) => {
      const reservation = reservations.find((item) => String(item.id) === String(payment.reservation_id));
      return {
        ...payment,
        _customer_name: first(reservation ?? {}, ["customer_name"]) ?? profileName(payment.customer_id),
        _reservation_code: first(reservation ?? {}, ["reservation_code", "id"]),
        _reservation_total_amount: first(reservation ?? {}, ["total_amount"]),
        _reservation_deposit_amount: first(reservation ?? {}, ["deposit_amount"]),
        _reservation_amount_paid: first(reservation ?? {}, ["amount_paid"]),
        _reservation_remaining_balance: first(reservation ?? {}, ["remaining_balance"]),
        _reservation_payment_status: first(reservation ?? {}, ["payment_status"]),
        _receipt_status: first(payment, ["proof_url"]) ? "Private receipt attached" : "Missing receipt",
      };
    });
  }
  return (byTable.orders ?? []).map((order) => {
    const reservation = reservations.find((item) => String(item.id) === String(order.reservation_id));
    const foodItems = (byTable.evently_food_order_items ?? []).filter(item => String(item.order_id) === String(order.id));
    const custom = String(order.order_kind ?? "") === "custom_food";
    return {
      ...order,
      _customer_name: first(order, ["customer_name"]) ?? first(reservation ?? {}, ["customer_name"]) ?? profileName(order.customer_id),
      _reservation_code: custom ? "Standalone food order" : first(reservation ?? {}, ["reservation_code", "id"]),
      _package_variant: first(reservation ?? {}, ["package_variant"]),
      _food_items: foodItems,
      _food_summary: custom ? foodItems.map(item => String(item.quantity) + "× " + String(item.item_name)).join(", ") || "Custom food order" : null,
    };
  });
}

function Icon({ name }: { name: string }) {
  const paths: Record<string, ReactNode> = {
    grid: <><rect x="3" y="3" width="7" height="7" rx="1" /><rect x="14" y="3" width="7" height="7" rx="1" /><rect x="3" y="14" width="7" height="7" rx="1" /><rect x="14" y="14" width="7" height="7" rx="1" /></>,
    calendar: <><rect x="3" y="5" width="18" height="16" rx="2" /><path d="M16 3v4M8 3v4M3 10h18" /></>,
    list: <><path d="M8 6h13M8 12h13M8 18h13" /><path d="M3 6h.01M3 12h.01M3 18h.01" /></>,
    users: <><circle cx="9" cy="8" r="4" /><path d="M2 21v-2a7 7 0 0 1 14 0v2M17 4a4 4 0 0 1 0 8M19 15a6 6 0 0 1 3 5" /></>,
    box: <><path d="m3 7 9 5 9-5-9-5-9 5Z" /><path d="m3 7 9 5v10l9-5V7M12 12v10" /></>,
    plus: <path d="M12 5v14M5 12h14" />,
    card: <><rect x="2" y="5" width="20" height="14" rx="2" /><path d="M2 10h20" /></>,
    star: <path d="m12 2 3 6 7 .9-5 4.8 1.2 7-6.2-3.3-6.2 3.3 1.2-7-5-4.8L9 8l3-6Z" />,
    chart: <><path d="M4 20V10M10 20V4M16 20v-7M22 20H2" /></>,
    bell: <><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4" /></>,
    clock: <><circle cx="12" cy="12" r="9" /><path d="M12 7v6l4 2" /></>,
    settings: <><circle cx="12" cy="12" r="3" /><path d="M19.4 15a2 2 0 0 0 .4 2.2l.1.1-2.6 2.6-.1-.1a2 2 0 0 0-2.2-.4 2 2 0 0 0-1.2 1.8V21h-3.6v-.2A2 2 0 0 0 9 19a2 2 0 0 0-2.2.4l-.1.1-2.6-2.6.1-.1A2 2 0 0 0 4.6 15a2 2 0 0 0-1.8-1.2H2v-3.6h.8A2 2 0 0 0 4.6 9a2 2 0 0 0-.4-2.2l-.1-.1 2.6-2.6.1.1A2 2 0 0 0 9 4.6a2 2 0 0 0 1.2-1.8V2h3.6v.8A2 2 0 0 0 15 4.6a2 2 0 0 0 2.2-.4l.1-.1 2.6 2.6-.1.1A2 2 0 0 0 19.4 9a2 2 0 0 0 1.8 1.2h.8v3.6h-.8a2 2 0 0 0-1.8 1.2Z" /></>,
    collapse: <><path d="m14 7-5 5 5 5" /><path d="M20 4v16" /></>,
    external: <><path d="M14 4h6v6M20 4l-9 9" /><path d="M18 13v6a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h6" /></>,
    logout: <><path d="M10 17l5-5-5-5M15 12H3" /><path d="M14 3h6v18h-6" /></>,
    search: <><circle cx="11" cy="11" r="7" /><path d="m20 20-4-4" /></>,
    pin: <><path d="M20 10c0 5-8 12-8 12S4 15 4 10a8 8 0 1 1 16 0Z" /><circle cx="12" cy="10" r="2.5" /></>,
    refresh: <><path d="M20 7v5h-5M4 17v-5h5" /><path d="M6.1 9a7 7 0 0 1 11.7-2L20 9M4 15l2.2 2a7 7 0 0 0 11.7-2" /></>,
    chevron: <path d="m9 18 6-6-6-6" />,
    message: <><path d="M21 11.5a8.4 8.4 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.4 8.4 0 0 1-3.8-.9L3 21l1.9-5.7a8.4 8.4 0 0 1-.9-3.8A8.5 8.5 0 0 1 8.7 3.9a8.4 8.4 0 0 1 3.8-.9h.5a8.5 8.5 0 0 1 8 8z" /></>,
  };
  return <svg aria-hidden="true" className="admin-icon" viewBox="0 0 24 24">{paths[name] ?? paths.grid}</svg>;
}

function first(row: Row, keys: string[]) {
  const key = keys.find((candidate) => row[candidate] !== undefined && row[candidate] !== null);
  return key ? row[key] : null;
}

function show(value: unknown, label = "") {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (typeof value === "number" && /amount|price|total|revenue/i.test(label)) return money.format(value);
  if (typeof value === "string" && /date$/i.test(label) && /^\d{4}-\d{2}-\d{2}$/.test(value)) return localDateLabel(value);
  if (typeof value === "string" && /(_at|date)$/i.test(label) && !Number.isNaN(Date.parse(value))) return date.format(new Date(value));
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function statusTone(value: unknown) {
  const normalized = String(value ?? "").toLowerCase();
  if (/confirm|verif|complete|paid|publish|active|available|ready/.test(normalized)) return "success";
  if (/pending|await|partial|prepar/.test(normalized)) return "warning";
  if (/cancel|reject|fail|inactive|unavailable/.test(normalized)) return "danger";
  return "info";
}

function paymentStatusLabel(value: unknown) {
  const normalized = String(value ?? "").toLowerCase();
  if (normalized === "partial") return "Partially Paid";
  if (normalized === "paid") return "Fully Paid";
  if (normalized === "pending") return "Pending Verification";
  if (normalized === "unpaid") return "Pending Payment";
  if (normalized === "deposit_verified") return "Deposit Verified";
  return show(value);
}

function paymentVerificationLabel(value: unknown) {
  const normalized = String(value ?? "").toLowerCase();
  if (normalized === "pending") return "Pending Verification";
  if (normalized === "verified") return "Verified";
  if (normalized === "rejected") return "Rejected — Resubmission Required";
  return show(value);
}

function reservationPaymentSummary(payment: Row) {
  const total = Number(first(payment, ["_reservation_total_amount", "total_amount"]) ?? 0);
  const deposit = Number(first(payment, ["_reservation_deposit_amount", "deposit_amount"]) ?? 0);
  const paid = Number(first(payment, ["_reservation_amount_paid", "amount_paid"]) ?? 0);
  const balanceValue = first(payment, ["_reservation_remaining_balance", "remaining_balance"]);
  const balance = balanceValue === null || balanceValue === undefined
    ? Math.max(0, total - paid)
    : Math.max(0, Number(balanceValue) || 0);
  const storedStatus = String(first(payment, ["_reservation_payment_status", "payment_status"]) ?? "").toLowerCase();
  const label = total > 0 && paid >= total
    ? "Fully Paid"
    : deposit > 0 && paid >= deposit && paid > 0
      ? "Deposit Verified · Partially Paid"
      : paid > 0 || storedStatus === "partial"
        ? "Partially Paid"
        : storedStatus === "pending" ? "Pending Verification" : "Pending Payment";
  return { balance, deposit, label, paid, total };
}

function Value({ value, label }: { value: unknown; label: string }) {
  const isStatus = /status|published|active|available|read/i.test(label);
  if (label === "Deposit %") return <>{value === null || value === undefined || value === "" ? "—" : `${show(value)}%`}</>;
  return isStatus
    ? <span className={`admin-status admin-status--${statusTone(value)}`}>{/payment status/i.test(label) ? paymentStatusLabel(value) : show(value, label)}</span>
    : <>{show(value, label)}</>;
}

type ActionMenuItem = { label: string; onSelect: () => void; disabled?: boolean };

function MoreActionsMenu({ label, items }: { label: string; items: ActionMenuItem[] }) {
  const [open, setOpen] = useState(false);
  const [position, setPosition] = useState({ top: 0, left: 0 });
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);
  const updatePosition = useCallback(() => {
    const trigger = triggerRef.current;
    if (!trigger) return;
    const rect = trigger.getBoundingClientRect();
    const menuWidth = menuRef.current?.getBoundingClientRect().width ?? 210;
    const menuHeight = menuRef.current?.getBoundingClientRect().height ?? items.length * 40 + 12;
    const left = Math.max(8, Math.min(rect.right - menuWidth, window.innerWidth - menuWidth - 8));
    const top = rect.bottom + menuHeight + 8 <= window.innerHeight
      ? rect.bottom + 5
      : Math.max(8, rect.top - menuHeight - 5);
    setPosition({ top, left });
  }, [items.length]);

  useEffect(() => {
    if (!open) return;
    updatePosition();
    const onPointerDown = (event: PointerEvent) => {
      const target = event.target as Node;
      if (!triggerRef.current?.contains(target) && !menuRef.current?.contains(target)) setOpen(false);
    };
    const onEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      setOpen(false);
      triggerRef.current?.focus();
    };
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onEscape);
    window.addEventListener("resize", updatePosition);
    window.addEventListener("scroll", updatePosition, true);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onEscape);
      window.removeEventListener("resize", updatePosition);
      window.removeEventListener("scroll", updatePosition, true);
    };
  }, [open, updatePosition]);

  const closeAndSelect = (item: ActionMenuItem) => {
    setOpen(false);
    item.onSelect();
  };

  return (
    <span className="admin-action-menu">
      <button
        aria-expanded={open}
        aria-haspopup="menu"
        aria-label={`More actions for ${label}`}
        className="admin-action-menu__trigger"
        onClick={(event) => { event.stopPropagation(); setOpen((current) => !current); }}
        onKeyDown={(event) => {
          if (event.key === "ArrowDown" || event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            setOpen(true);
            requestAnimationFrame(() => menuRef.current?.querySelector<HTMLButtonElement>("button:not(:disabled)")?.focus());
          }
        }}
        ref={triggerRef}
        title={`More actions for ${label}`}
        type="button"
      >⋯</button>
      {open && typeof document !== "undefined" && createPortal(
        <div
          aria-label={`Actions for ${label}`}
          className="admin-action-menu__items"
          onClick={(event) => event.stopPropagation()}
          onKeyDown={(event) => {
            const enabled = Array.from(menuRef.current?.querySelectorAll<HTMLButtonElement>("button:not(:disabled)") ?? []);
            const current = enabled.indexOf(document.activeElement as HTMLButtonElement);
            if (event.key === "ArrowDown" || event.key === "ArrowUp") {
              event.preventDefault();
              const delta = event.key === "ArrowDown" ? 1 : -1;
              enabled[(current + delta + enabled.length) % enabled.length]?.focus();
            } else if (event.key === "Home") { event.preventDefault(); enabled[0]?.focus(); }
            else if (event.key === "End") { event.preventDefault(); enabled.at(-1)?.focus(); }
          }}
          ref={menuRef}
          role="menu"
          style={{ position: "fixed", top: position.top, left: position.left }}
        >
          {items.map((item) => (
            <button
              disabled={item.disabled}
              key={item.label}
              onClick={() => closeAndSelect(item)}
              role="menuitem"
              type="button"
            >{item.label}</button>
          ))}
        </div>,
        document.body,
      )}
    </span>
  );
}

function dateOnlyKey(value: unknown) {
  return String(value ?? "").slice(0, 10);
}

function localDateLabel(value: string) {
  const [year, month, day] = value.split("-").map(Number);
  if (!year || !month || !day) return value;
  return new Date(year, month - 1, day).toLocaleDateString("en-PH", {
    month: "long",
    day: "numeric",
    year: "numeric",
  });
}

function LoadingState() {
  return <div className="admin-skeleton" aria-label="Loading data">{Array.from({ length: 6 }, (_, index) => <span key={index} />)}</div>;
}

function ErrorState({ message, retry }: { message: string; retry: () => void }) {
  const permission = /permission|policy|row-level|401|403|jwt/i.test(message);
  return (
    <div className="admin-state admin-state--error" role="alert">
      <strong>{permission ? "Administrative access was not granted" : "This data could not be loaded"}</strong>
      <p>{message}</p>
      <button onClick={retry} type="button">Retry</button>
    </div>
  );
}

const normalizedStatus = (row: Row, keys = ["status"]) =>
  String(first(row, keys) ?? "").toLowerCase();

const reservationSchedule = (row: Row) => {
  const start = String(first(row, ["start_time"]) ?? "").slice(0, 5);
  const end = String(first(row, ["end_time"]) ?? "").slice(0, 5);
  if (!start || !end) return "Not assigned";
  return `${start}–${end}${end <= start ? " · next day" : ""}`;
};

function ReservationsView({ go, canManageReservations }: { go: (path: string) => void; canManageReservations: boolean }) {
  const [rows, setRows] = useState<Row[]>([]);
  const [state, setState] = useState<LoadState>("loading");
  const [error, setError] = useState("");
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState("All");
  const [serviceFilter, setServiceFilter] = useState("All");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [sortBy, setSortBy] = useState("newest");
  const [selectedDate, setSelectedDate] = useState("");
  const [month, setMonth] = useState(() => {
    const today = new Date();
    return new Date(today.getFullYear(), today.getMonth(), 1);
  });
  const [selected, setSelected] = useState<Row | null>(null);
  const [rejectTarget, setRejectTarget] = useState("");
  const [scheduleEditTarget, setScheduleEditTarget] = useState("");
  const [page, setPage] = useState(1);
  const recordsRef = useRef<HTMLElement | null>(null);
  const pageSize = 10;
  const load = useCallback(async (silent = false) => {
    if (!silent) setState("loading");
    setError("");
    try {
      setRows(await loadAdminRows("reservations", "reservations"));
      setState("ready");
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Reservations could not be loaded.");
      setState("error");
    }
  }, []);
  useEffect(() => {
    void load();
    const refresh = () => { void load(true); };
    window.addEventListener("evently-admin-data-changed", refresh);
    const channel = supabase.channel("admin-reservation-management")
      .on("postgres_changes", { event: "*", schema: "public", table: "reservations" }, refresh)
      .subscribe();
    return () => {
      window.removeEventListener("evently-admin-data-changed", refresh);
      void supabase.removeChannel(channel);
    };
  }, [load]);
  useEffect(() => {
    const recordId = new URLSearchParams(window.location.search).get("record");
    if (!recordId || !rows.length) return;
    const match = rows.find((row) => String(row.id) === recordId);
    if (match) setSelected(match);
  }, [rows]);
  useEffect(() => {
    if (!selected) return;
    const latest = rows.find((row) => String(row.id) === String(selected.id));
    if (latest && latest !== selected) setSelected(latest);
  }, [rows]);
  const services = Array.from(new Set(rows.map((row) => String(first(row, ["service_type", "service"]) ?? "")).filter(Boolean)));
  const statusTabs = ["All", "Pending", "Confirmed", "Completed", "Cancelled"];
  const counts = Object.fromEntries(statusTabs.map((item) => [
    item,
    item === "All" ? rows.length : rows.filter((row) => normalizedStatus(row) === item.toLowerCase()).length,
  ]));
  const visible = useMemo(() => rows.filter((row) => {
    const term = search.trim().toLowerCase();
    const dateValue = dateOnlyKey(first(row, ["reservation_date"]));
    return (!term || JSON.stringify(row).toLowerCase().includes(term))
      && (statusFilter === "All" || normalizedStatus(row) === statusFilter.toLowerCase())
      && (serviceFilter === "All" || String(first(row, ["service_type", "service"]) ?? "") === serviceFilter)
      && (selectedDate ? dateValue === selectedDate : (!dateFrom || dateValue >= dateFrom) && (!dateTo || dateValue <= dateTo));
  }).sort((left, right) => {
    const leftDate = String(first(left, ["reservation_date", "created_at"]) ?? "");
    const rightDate = String(first(right, ["reservation_date", "created_at"]) ?? "");
    if (sortBy === "oldest" || sortBy === "date_asc") return leftDate.localeCompare(rightDate);
    if (sortBy === "total_desc") return Number(first(right, ["total_amount"]) ?? 0) - Number(first(left, ["total_amount"]) ?? 0);
    return rightDate.localeCompare(leftDate);
  }), [dateFrom, dateTo, rows, search, selectedDate, serviceFilter, sortBy, statusFilter]);
  useEffect(() => { setPage(1); }, [dateFrom, dateTo, search, selectedDate, serviceFilter, sortBy, statusFilter]);
  const pageCount = Math.max(1, Math.ceil(visible.length / pageSize));
  const paginated = visible.slice((page - 1) * pageSize, page * pageSize);
  if (state === "loading") return <LoadingState />;
  if (state === "error") return <ErrorState message={error} retry={load} />;
  const calendarDays = Array.from({ length: 42 }, (_, index) => {
    const day = index - new Date(month.getFullYear(), month.getMonth(), 1).getDay() + 1;
    const dateValue = new Date(month.getFullYear(), month.getMonth(), day);
    const key = `${dateValue.getFullYear()}-${String(dateValue.getMonth() + 1).padStart(2, "0")}-${String(dateValue.getDate()).padStart(2, "0")}`;
    const inMonth = dateValue.getMonth() === month.getMonth();
    const bookings = rows.filter((row) => dateOnlyKey(first(row, ["reservation_date"])) === key);
    return { dateValue, key, day: dateValue.getDate(), inMonth, bookings };
  });
  const selectedDateLabel = selectedDate ? localDateLabel(selectedDate) : "";
  const selectDate = (key: string) => {
    setSelectedDate(key);
    window.requestAnimationFrame(() => recordsRef.current?.scrollIntoView({ behavior: "smooth", block: "start" }));
  };
  return (
    <>
      <div className="admin-reservation-summary">
        {["All", "Pending", "Confirmed", "Completed"].map((item) => (
          <article className={`admin-reservation-summary__${item.toLowerCase()}`} key={item}>
            <span>{item === "All" ? "Total reservations" : item}</span>
            <strong>{counts[item]}</strong>
          </article>
        ))}
      </div>
      <section aria-label="Reservation calendar" className="admin-card admin-reservation-calendar">
        <div className="admin-calendar-heading">
          <button aria-label="Previous month" onClick={() => { setSelectedDate(""); setMonth((current) => new Date(current.getFullYear(), current.getMonth() - 1, 1)); }} type="button">Previous</button>
          <h2>{month.toLocaleDateString("en-PH", { month: "long", year: "numeric" })}</h2>
          <button aria-label="Next month" onClick={() => { setSelectedDate(""); setMonth((current) => new Date(current.getFullYear(), current.getMonth() + 1, 1)); }} type="button">Next</button>
        </div>
        <div aria-label="Reservation statuses" className="admin-calendar-legend">
          {["Pending", "Confirmed", "Completed", "Cancelled"].map((item) => <span key={item}><i className={`is-${statusTone(item)}`} />{item}</span>)}
        </div>
        <div className="admin-calendar-week">{["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map((day) => <span key={day}>{day}</span>)}</div>
        <div className="admin-reservation-calendar__grid">
          {calendarDays.map(({ key, day, inMonth, bookings }) => (
            <button
              aria-label={`${localDateLabel(key)}${bookings.length ? `, ${bookings.length} reservation${bookings.length === 1 ? "" : "s"}` : ", no reservations"}`}
              aria-pressed={selectedDate === key}
              className={`${inMonth ? "" : "is-outside"} ${selectedDate === key ? "is-selected" : ""}`.trim()}
              disabled={!inMonth}
              key={key}
              onClick={() => selectDate(key)}
              type="button"
            >
              <span>{day}</span>
              {bookings.length > 0 && <span className="admin-reservation-calendar__count">{bookings.length}</span>}
              {bookings.length > 0 && <span className="admin-reservation-calendar__indicators">{["pending", "confirmed", "completed", "cancelled"].map((status) => {
                const count = bookings.filter((row) => normalizedStatus(row) === status).length;
                return count ? <i aria-label={`${count} ${status}`} className={`is-${statusTone(status)}`} key={status} /> : null;
              })}</span>}
            </button>
          ))}
        </div>
      </section>
      <div className="admin-reservation-tools">
        <label className="admin-search"><span>Search reservations</span><div><Icon name="search" /><input onChange={(event) => setSearch(event.target.value)} placeholder="Code, customer, package…" value={search} /></div></label>
        <label><span>Service</span><select onChange={(event) => setServiceFilter(event.target.value)} value={serviceFilter}><option>All</option>{services.map((service) => <option key={service}>{service}</option>)}</select></label>
        <label><span>From</span><input onChange={(event) => setDateFrom(event.target.value)} type="date" value={dateFrom} /></label>
        <label><span>To</span><input min={dateFrom || undefined} onChange={(event) => setDateTo(event.target.value)} type="date" value={dateTo} /></label>
        <label><span>Sort</span><select onChange={(event) => setSortBy(event.target.value)} value={sortBy}><option value="newest">Newest first</option><option value="oldest">Oldest first</option><option value="date_asc">Booking date ↑</option><option value="date_desc">Booking date ↓</option><option value="total_desc">Highest total</option></select></label>
        <button className="admin-secondary-button" onClick={() => void load()} type="button"><Icon name="refresh" /> Refresh</button>
      </div>
      <div className="admin-filter-tabs admin-status-tabs" role="tablist" aria-label="Reservation status">
        {statusTabs.map((item) => <button aria-selected={statusFilter === item} className={statusFilter === item ? "is-active" : ""} key={item} onClick={() => setStatusFilter(item)} role="tab" type="button">{item === "All" ? "All Reservations" : item}<b>{counts[item]}</b></button>)}
      </div>
      <section className="admin-card admin-table-card admin-reservations-card" id="reservation-records" ref={recordsRef}>
        <div className="admin-card-heading"><div><h2>{selectedDate ? `Reservations for ${selectedDateLabel}` : "Reservation records"}</h2><p>{visible.length} matching live booking{visible.length === 1 ? "" : "s"}</p></div>{selectedDate && <button className="admin-quiet-button" onClick={() => setSelectedDate("")} type="button">Clear Date Filter</button>}</div>
        {!visible.length ? <div className="admin-empty"><strong>{selectedDate ? `No reservations for ${selectedDateLabel}` : "No reservations match these filters"}</strong><p>{selectedDate ? "Choose another date or clear the date filter to see all reservations." : "Clear a filter or refresh to load the latest Supabase records."}</p></div> : <>
          <div className="admin-table-scroll">
            <table>
              <thead><tr><th>Reservation</th><th>Customer</th><th>Package / Service</th><th>Date</th><th>Schedule</th><th>Venue / Resource</th><th>Total</th><th>Payment</th><th>Booking</th><th>Action</th></tr></thead>
              <tbody>{paginated.map((row, index) => <tr key={String(row.id ?? index)} onClick={() => setSelected(row)} onKeyDown={(event) => { if (event.key === "Enter" || event.key === " ") setSelected(row); }} tabIndex={0}>
                <td data-label="Reservation"><strong>{show(first(row, ["reservation_code", "id"]))}</strong></td>
                <td data-label="Customer">{show(first(row, ["_customer_name", "customer_name", "customer_id"]))}</td>
                <td data-label="Package / Service"><strong>{show(first(row, ["package_name", "package_id"]))}</strong><small>{show(first(row, ["service_type", "service"]))}</small></td>
                <td data-label="Date">{show(first(row, ["reservation_date"]), "reservation_date")}</td>
                <td data-label="Schedule">{reservationSchedule(row)}</td>
                <td data-label="Venue / Resource">{show(first(row, ["resource_name", "resource_key"]))}</td>
                <td data-label="Total">{show(first(row, ["total_amount"]), "total_amount")}</td>
                <td data-label="Payment"><Value label="payment status" value={first(row, ["payment_status"])} /></td>
                <td data-label="Booking"><Value label="status" value={first(row, ["status"])} /></td>
                <td data-label="Action" onClick={(event) => event.stopPropagation()} onKeyDown={(event) => event.stopPropagation()}>
                  <MoreActionsMenu
                    label={show(first(row, ["reservation_code", "id"]))}
                    items={[
                      { label: "Open Reservation", onSelect: () => setSelected(row) },
                      ...(canManageReservations ? [
                        { label: "Review Schedule / Payment", disabled: normalizedStatus(row) !== "pending", onSelect: () => setSelected(row) },
                        { label: "Reject Booking", disabled: normalizedStatus(row) !== "pending", onSelect: () => { setSelected(row); setRejectTarget(String(row.id)); } },
                        { label: "Edit Schedule", disabled: normalizedStatus(row) !== "pending", onSelect: () => { setScheduleEditTarget(String(row.id)); setSelected(row); } },
                      ] : []),
                    ]}
                  />
                </td>
              </tr>)}</tbody>
            </table>
          </div>
          {visible.length > pageSize && <div className="admin-pagination"><span>Showing {(page - 1) * pageSize + 1}–{Math.min(page * pageSize, visible.length)} of {visible.length}</span><div><button disabled={page === 1} onClick={() => setPage((current) => current - 1)} type="button">Previous</button><b>{page} / {pageCount}</b><button disabled={page === pageCount} onClick={() => setPage((current) => current + 1)} type="button">Next</button></div></div>}
        </>}
      </section>
      {selected && <DetailDrawer canManageReservations={canManageReservations} onChanged={load} onNavigate={go} onClose={() => { setSelected(null); setScheduleEditTarget(""); setRejectTarget(""); }} openRejectionModal={rejectTarget === String(selected.id)} openScheduleEditor={scheduleEditTarget === String(selected.id)} row={selected} section="reservations" title={show(first(selected, ["reservation_code", "id"]))} />}
    </>
  );
}

function DataTable({ section, go, defaultFilter = "All" }: { section: string; go?: (path: string) => void; defaultFilter?: string }) {
  const table = tableBySection[section];
  const columns = columnsBySection[section] ?? [];
  const [rows, setRows] = useState<Row[]>([]);
  const [state, setState] = useState<LoadState>("loading");
  const [error, setError] = useState("");
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState<Row | null>(null);
  const [rejectOnOpen, setRejectOnOpen] = useState(false);
  const [filter, setFilter] = useState(defaultFilter);
  const [page, setPage] = useState(1);
  const pageSize = 12;

  const load = useCallback(async (silent = false) => {
    if (!silent) setState("loading");
    setError("");
    try {
      const data = await loadAdminRows(section, table);
      setRows(data);
      setState("ready");
    } catch (queryError) {
      setError(queryError instanceof Error ? queryError.message : "Admin data could not be loaded.");
      setState("error");
    }
  }, [section, table]);

  useEffect(() => {
    void load();
    const interval = window.setInterval(() => { void load(true); }, 30000);
    const refresh = () => { void load(true); };
    window.addEventListener("evently-admin-data-changed", refresh);
    return () => {
      window.clearInterval(interval);
      window.removeEventListener("evently-admin-data-changed", refresh);
    };
  }, [load]);
  useEffect(() => {
    if (!table) return;
    const channel = supabase.channel(`admin-${table}`)
      .on("postgres_changes", { event: "*", schema: "public", table }, () => { void load(true); })
      .subscribe();
    return () => { void supabase.removeChannel(channel); };
  }, [load, table]);
  useEffect(() => {
    const recordId = new URLSearchParams(window.location.search).get("record");
    if (!recordId || !rows.length) return;
    const match = rows.find((row) => String(row.id) === recordId);
    if (match) setSelected(match);
  }, [rows]);
  const visible = useMemo(() => {
    const term = search.trim().toLowerCase();
    return rows.filter((row) => {
      const matchesSearch = !term || JSON.stringify(row).toLowerCase().includes(term);
      const service = String(first(row, ["service", "service_type", "category"]) ?? "");
      const rowFilter = section === "payments"
        ? String(first(row, ["verification_status", "payment_status", "status"]) ?? "")
        : section === "catering-menu"
          ? String(first(row, ["category"]) ?? "")
          : service;
      return matchesSearch && (filter === "All" || rowFilter.toLowerCase().includes(filter.toLowerCase()));
    });
  }, [filter, rows, search, section]);
  const pageCount = Math.max(1, Math.ceil(visible.length / pageSize));
  const paginated = visible.slice((page - 1) * pageSize, page * pageSize);
  const filters = section === "packages"
    ? ["All", "Catering", "Resort", "Staycation"]
    : section === "payments"
      ? ["All", "Pending", "Verified", "Rejected"]
    : section === "catering-menu"
      ? ["All", "Beef", "Pork", "Chicken", "Seafood", "Vegetable", "Pancit", "Dessert", "Drinks"]
      : [];

  useEffect(() => { setPage(1); }, [filter, search]);

  const exportCsv = () => {
    if (!visible.length) return;
    const keys = Array.from(new Set(visible.flatMap(Object.keys)));
    const cell = (value: unknown) => `"${String(value ?? "").replace(/"/g, '""')}"`;
    const csv = [keys.join(","), ...visible.map((row) => keys.map((key) => cell(row[key])).join(","))].join("\n");
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
    link.download = `evently-${table}.csv`;
    link.click();
    URL.revokeObjectURL(link.href);
  };

  if (state === "loading") return <LoadingState />;
  if (state === "error") return <ErrorState message={error} retry={load} />;
  return (
    <>
      <div className="admin-toolbar">
        <label className="admin-search"><span>Search</span><div><Icon name="search" /><input onChange={(event) => setSearch(event.target.value)} placeholder={`Search ${table.replace(/_/g, " ")}…`} value={search} /></div></label>
        <div className="admin-toolbar-actions"><button className="admin-quiet-button" onClick={() => void load()} type="button"><Icon name="refresh" /> Refresh</button><button className="admin-secondary-button" disabled={!visible.length} onClick={exportCsv} type="button">Export CSV</button></div>
      </div>
      {filters.length > 0 && <div className="admin-filter-tabs" role="group" aria-label={`${section} filters`}>{filters.map((item) => <button className={filter === item ? "is-active" : ""} key={item} onClick={() => setFilter(item)} type="button">{item}</button>)}</div>}
      {section === "payments" && <div className="admin-mini-stats">{["pending", "verified", "rejected"].map((item) => <div key={item}><span className={`admin-status admin-status--${statusTone(item)}`}>{item}</span><strong>{rows.filter((row) => String(first(row, ["verification_status", "payment_status", "status"]) ?? "").toLowerCase() === item).length}</strong><small>payments</small></div>)}</div>}
      <section className="admin-card admin-table-card">
        <div className="admin-card-heading"><div><h2>{sections.find(([path]) => path === section)?.[1]}</h2><p>{visible.length} live record{visible.length === 1 ? "" : "s"}</p></div></div>
        {!visible.length ? (
          <div className="admin-empty"><strong>No records found</strong><p>Records allowed by the current Supabase RLS policies will appear here.</p></div>
        ) : (
          <div className="admin-table-scroll">
            <table>
              <thead><tr>{columns.map((column) => <th key={column.label}>{column.label}</th>)}<th>Actions</th></tr></thead>
              <tbody>{paginated.map((row, index) => (
                <tr key={String(row.id ?? index)}>
                  {columns.map((column) => <td key={column.label}><Value label={column.label} value={first(row, column.keys)} /></td>)}
                  <td onClick={(event) => event.stopPropagation()}><MoreActionsMenu
                    label={show(first(row, ["reservation_code", "order_code", "reference_number", "name", "id"]))}
                    items={[
                      { label: section === "reservations" ? "Open Reservation" : section === "customers" ? "View Customer Profile" : "View Details", onSelect: () => setSelected(row) },
                      ...(section === "reservations" ? [
                        { label: "Review Schedule / Payment", onSelect: () => setSelected(row) },
                        { label: "Reject Booking", disabled: normalizedStatus(row) !== "pending", onSelect: () => { setSelected(row); setRejectOnOpen(true); } },
                      ] : []),
                      ...(section === "customers" ? [
                        { label: "View Booking History", onSelect: () => setSelected(row) },
                        { label: "View Payment History", onSelect: () => setSelected(row) },
                      ] : []),
                      ...(go && section !== "customers" && row.customer_id ? [{ label: "View Customer", onSelect: () => go(`customers?record=${encodeURIComponent(String(row.customer_id))}`) }] : []),
                      ...(go && section !== "reservations" && row.reservation_id ? [{ label: "View Reservation", onSelect: () => go(`reservations?record=${encodeURIComponent(String(row.reservation_id))}`) }] : []),
                    ]}
                  /></td>
                </tr>
              ))}</tbody>
            </table>
          </div>
        )}
        {visible.length > pageSize && <div className="admin-pagination"><span>Showing {(page - 1) * pageSize + 1}–{Math.min(page * pageSize, visible.length)} of {visible.length}</span><div><button disabled={page === 1} onClick={() => setPage((current) => current - 1)} type="button">Previous</button><b>{page} / {pageCount}</b><button disabled={page === pageCount} onClick={() => setPage((current) => current + 1)} type="button">Next</button></div></div>}
      </section>
      {selected && <DetailDrawer row={selected} section={section} title={show(first(selected, columns[0]?.keys ?? ["id"]))} onChanged={load} onClose={() => { setSelected(null); setRejectOnOpen(false); }} openRejectionModal={rejectOnOpen} />}
    </>
  );
}

type CatalogEntity = "package" | "package_variant" | "addon" | "menu_item";
type CatalogEditor = { entity: CatalogEntity; row: Row };

function CatalogEditorDialog({ editor, onClose, onSaved }: { editor: CatalogEditor; onClose: () => void; onSaved: () => void | Promise<void> }) {
  const { entity, row } = editor;
  const [name, setName] = useState(String(first(row, ["name"]) ?? ""));
  const [description, setDescription] = useState(String(first(row, ["description"]) ?? ""));
  const [category, setCategory] = useState(String(first(row, ["category"]) ?? ""));
  const [price, setPrice] = useState(String(first(row, ["price"]) ?? "0"));
  const [trayPrice, setTrayPrice] = useState(String(first(row, ["tray_price"]) ?? "0"));
  const [adjustment, setAdjustment] = useState("");
  const [guestCapacity, setGuestCapacity] = useState(String(first(row, ["guest_capacity"]) ?? ""));
  const isPoolTour = entity === "package" && (String(row.package_category ?? "").toLowerCase() === "pool_tour"
    || ["4ae972a8-6503-4776-90c9-899246cbc4dc", "5afda244-a615-4bd3-98eb-d360d000100b", "925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8"].includes(String(row.id ?? "")));
  const resortService = String(row.service_type ?? "").trim().toLowerCase() === "resort";
  const resortRateByName: Record<string, number> = {
    "standard room": 3000,
    "kubo room": 1500,
    "non-air-conditioned venue": 10000,
    "air-conditioned venue": 15000,
  };
  const originalPackageName = String(row.name ?? "").trim().toLowerCase();
  const lockedResortRate = entity === "package" && resortService ? resortRateByName[originalPackageName] : undefined;
  const isStandardRoom = entity === "package" && resortService && originalPackageName === "standard room";
  const resortVenueDuration = entity === "package" && resortService
    ? originalPackageName === "non-air-conditioned venue" ? 300
      : originalPackageName === "air-conditioned venue" ? 240 : undefined
    : undefined;
  const isResortVenueOnly = resortVenueDuration !== undefined;
  const [poolCapacityVerified, setPoolCapacityVerified] = useState(row.pool_capacity_verified === true);
  const [poolMaxGuestCount, setPoolMaxGuestCount] = useState(String(row.max_guest_count ?? ""));
  const [poolCapacityReason, setPoolCapacityReason] = useState("");
  const [depositPercentage, setDepositPercentage] = useState(String(first(row, ["deposit_percentage"]) ?? ""));
  const [scheduleMode, setScheduleMode] = useState(String(first(row, ["schedule_mode"]) ?? "admin_assign"));
  const [operatingStart, setOperatingStart] = useState(String(first(row, ["operating_start_time"]) ?? "").slice(0, 5));
  const [operatingEnd, setOperatingEnd] = useState(String(first(row, ["operating_end_time"]) ?? "").slice(0, 5));
  const [durationMinutes, setDurationMinutes] = useState(String(first(row, ["duration_minutes"]) ?? ""));
  const [compatibleServices, setCompatibleServices] = useState(Array.isArray(row.compatible_services) ? row.compatible_services.join(", ") : "");
  const [hasAircon, setHasAircon] = useState(Boolean(row.has_aircon));
  const [active, setActive] = useState(entity === "menu_item" ? row.is_available !== false && row.is_active !== false : Boolean(first(row, ["is_active"]) ?? true));
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const numericPrice = Number(price);
  const suggestedPrice = Number.isFinite(numericPrice) && Number.isFinite(Number(adjustment))
    ? Math.round(numericPrice * (1 + Number(adjustment) / 100) * 100) / 100
    : 0;
  const isPriceChanged = numericPrice !== Number(first(row, ["price"]));
  const poolUnitRateById: Record<string, number> = {
    "4ae972a8-6503-4776-90c9-899246cbc4dc": 100,
    "5afda244-a615-4bd3-98eb-d360d000100b": 150,
    "925a1e5e-e59b-41d5-9b7a-f63fe74fe0f8": 200,
  };
  const expectedPoolUnitRate = isPoolTour ? poolUnitRateById[String(row.id ?? "")] : undefined;
  const nextPoolMaximum = poolMaxGuestCount.trim() ? Number(poolMaxGuestCount) : null;
  const poolMinimumGuestCount = isPoolTour ? 20 : Math.max(1, Number(row.min_guest_count ?? 1));
  const poolCapacityChanged = isPoolTour && (poolCapacityVerified !== (row.pool_capacity_verified === true)
    || nextPoolMaximum !== (row.max_guest_count == null ? null : Number(row.max_guest_count))
    || (poolCapacityVerified && (!row.pool_capacity_audit_id
      || !Number.isInteger(nextPoolMaximum)
      || (nextPoolMaximum ?? 0) < poolMinimumGuestCount)));

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => { if (event.key === "Escape" && !busy) onClose(); };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [busy, onClose]);

  const save = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (busy) return;
    if (!name.trim()) { setMessage("Enter a name."); return; }
    if (!Number.isFinite(numericPrice) || numericPrice < 0) { setMessage("Enter a valid non-negative price."); return; }
    if (entity === "menu_item" && (!Number.isFinite(Number(trayPrice)) || Number(trayPrice)<100 || Number(trayPrice)>100000)) { setMessage("Individual tray price must be between ₱100 and ₱100,000."); return; }
    if (isPoolTour && expectedPoolUnitRate !== undefined && numericPrice !== expectedPoolUnitRate) {
      setMessage(`This verified per-person tour rate is ${money.format(expectedPoolUnitRate)}. Change rates only through the reviewed pool pricing migration.`);
      return;
    }
    if (lockedResortRate !== undefined && (numericPrice !== lockedResortRate || name.trim().toLowerCase() !== originalPackageName)) {
      setMessage(`This confirmed Resort rate is fixed at ${money.format(lockedResortRate)}. Change its rate or package identity only through a reviewed rate-sheet migration.`);
      return;
    }
    if (lockedResortRate !== undefined && Number(depositPercentage) !== 30) {
      setMessage("The confirmed Resort packages use a 30% deposit.");
      return;
    }
    if (isStandardRoom && guestCapacity !== "5") {
      setMessage("Standard Room occupancy is fixed at 4–5 guests per room.");
      return;
    }
    if (isResortVenueOnly && (scheduleMode !== "customer_select"
      || Number(durationMinutes) !== resortVenueDuration
      || !operatingStart || !operatingEnd || operatingStart === operatingEnd)) {
      setMessage(`Venue Only needs business-confirmed operating hours and its fixed ${resortVenueDuration / 60}-hour duration.`);
      return;
    }
    if (!isPoolTour && guestCapacity && (!Number.isInteger(Number(guestCapacity)) || Number(guestCapacity) < 1)) {
      setMessage("Guest capacity must be a positive whole number.");
      return;
    }
    if (isPoolTour && poolCapacityVerified
      && (!Number.isInteger(nextPoolMaximum) || (nextPoolMaximum ?? 0) < 20 || (nextPoolMaximum ?? 0) > 50)) {
      setMessage("Enter the actual physical maximum as a whole number between 20 and 50 guests.");
      return;
    }
    if (poolCapacityChanged && !poolCapacityReason.trim()) {
      setMessage("Record why the physical pool capacity is being verified or withdrawn.");
      return;
    }
    if (depositPercentage && (!Number.isFinite(Number(depositPercentage)) || Number(depositPercentage) < 0 || Number(depositPercentage) > 100)) {
      setMessage("Deposit percentage must be between 0 and 100.");
      return;
    }
    if (isPriceChanged && !window.confirm(`Confirm price change from ${money.format(Number(first(row, ["price"]) ?? 0))} to ${money.format(numericPrice)}? New bookings will use this price; existing reservation totals will not change.`)) return;

    const patch: Record<string, unknown> = { name: name.trim(), price: numericPrice };
    if (entity === "package") {
      Object.assign(patch, {
        description,
        deposit_percentage: depositPercentage || null,
        is_active: active,
      });
      if (!isPoolTour) patch.guest_capacity = guestCapacity || null;
    } else if (entity === "package_variant") {
      Object.assign(patch, {
        guest_capacity: guestCapacity || null,
        has_aircon: hasAircon,
        is_active: active,
      });
    } else if (entity === "addon") {
      Object.assign(patch, {
        description,
        compatible_services: compatibleServices.split(",").map((item) => item.trim().toLowerCase()).filter(Boolean),
        is_active: active,
      });
    } else {
      Object.assign(patch, { category: category.trim(), is_active: active, is_available: active });
      if (Number(trayPrice) !== Number(first(row,["tray_price"]))) patch.tray_price=Number(trayPrice);
      if (!category.trim()) { setMessage("Enter a menu category."); return; }
    }

    setBusy(true);
    setMessage("");
    const result = entity === "menu_item"
      ? await supabase.rpc("evently_admin_update_catering_menu_item", { p_id: String(row.id ?? ""), p_patch: patch })
      : await supabase.rpc("admin_update_evently_catalog", { p_entity: entity, p_id: String(row.id ?? ""), p_patch: patch });
    if (result.error) { setBusy(false); setMessage(result.error.message); return; }
    if (entity === "package") {
      const schedule = await supabase.rpc("evently_admin_set_package_schedule", {
        p_package_id: String(row.id ?? ""),
        p_schedule_mode: scheduleMode,
        p_operating_start_time: operatingStart || null,
        p_operating_end_time: operatingEnd || null,
        p_duration_minutes: durationMinutes ? Number(durationMinutes) : null,
      });
      if (schedule.error) {
        setBusy(false);
        setMessage(`Package details were saved, but its schedule was not: ${schedule.error.message}`);
        await onSaved();
        window.dispatchEvent(new Event("evently-catalog-changed"));
        return;
      }
    }
    if (poolCapacityChanged) {
      const { error: capacityError } = await supabase.rpc("evently_admin_set_pool_capacity", {
        p_package_id: String(row.id ?? ""),
        p_capacity_verified: poolCapacityVerified,
        p_max_guest_count: poolCapacityVerified ? nextPoolMaximum : null,
        p_reason: poolCapacityReason.trim(),
      });
      if (capacityError) {
        setBusy(false);
        setMessage(`Catalog details${entity === "package" ? " and schedule" : ""} were saved, but pool capacity was not: ${capacityError.message}`);
        await onSaved();
        window.dispatchEvent(new Event("evently-catalog-changed"));
        return;
      }
    }
    setBusy(false);
    await onSaved();
    window.dispatchEvent(new Event("evently-catalog-changed"));
    onClose();
  };

  const title = entity === "package_variant" ? "Edit package variant" : entity === "menu_item" ? "Edit catering menu item" : entity === "addon" ? "Edit add-on" : "Edit package or service";
  return (
    <div className="admin-modal-wrap">
      <button aria-label="Close editor" className="admin-modal-backdrop" onClick={onClose} type="button" />
      <section aria-labelledby="admin-catalog-editor-title" aria-modal="true" className="admin-editor-modal" role="dialog">
        <div className="admin-editor-modal__heading"><div><span>Catalog management</span><h2 id="admin-catalog-editor-title">{title}</h2></div><button aria-label="Close editor" onClick={onClose} type="button">×</button></div>
        <form onSubmit={(event) => void save(event)}>
          {entity === "menu_item" && <label>Category<select onChange={(event) => setCategory(event.target.value)} required value={category}>{cateringMenuCategories.map((item) => <option key={item}>{item}</option>)}</select></label>}
          <label>Name<input onChange={(event) => setName(event.target.value)} readOnly={lockedResortRate !== undefined} required value={name} /></label>
          {(entity === "package" || entity === "addon") && <label>Description<textarea onChange={(event) => setDescription(event.target.value)} rows={3} value={description} /></label>}
          <label>{entity === "menu_item" ? "Package menu price per guest (PHP)" : "Current price (PHP)"}<input min="0" onChange={(event) => setPrice(event.target.value)} readOnly={lockedResortRate !== undefined} required step="0.01" type="number" value={price} /></label>
          {entity === "menu_item" && <label>Individual food order price (PHP per tray/container) · Owner only<input min="100" max="100000" step="0.01" type="number" required value={trayPrice} onChange={event=>setTrayPrice(event.target.value)}/><small>Used for customizable Food Orders &amp; Party Trays. Existing catering package pricing stays separate. Only Owner may change individual prices.</small></label>}
          <div className="admin-price-helper"><label>Optional adjustment (%)<input min="0" onChange={(event) => setAdjustment(event.target.value)} placeholder="For example, 5" step="0.01" type="number" value={adjustment} /></label><p>Suggested price: <strong>{money.format(suggestedPrice)}</strong></p><button onClick={() => setPrice(suggestedPrice.toFixed(2))} type="button">Use suggestion</button></div>
          {(entity === "package_variant" || (entity === "package" && !isPoolTour)) && <label>Guest capacity<input min="1" onChange={(event) => setGuestCapacity(event.target.value)} placeholder="Not configured" readOnly={isStandardRoom} step="1" type="number" value={guestCapacity} /></label>}
          {isPoolTour && <section className="admin-pool-capacity-editor"><h3>Pool physical capacity</h3><p>Enter the maximum number of guests confirmed by an on-site physical capacity check. The legacy guest_capacity value is not evidence. The verified value is recorded on the shared pool resource; every verified tour using it must use the same maximum.</p><label className="admin-editor-checkbox"><input checked={poolCapacityVerified} onChange={(event) => setPoolCapacityVerified(event.target.checked)} type="checkbox" /> I have physically verified this pool tour’s maximum capacity</label><label>Verified maximum guests<input disabled={!poolCapacityVerified} max={50} min={poolMinimumGuestCount} onChange={(event) => setPoolMaxGuestCount(event.target.value)} placeholder="Enter the on-site verified maximum" step="1" type="number" value={poolMaxGuestCount} /></label><label>Capacity verification note<textarea maxLength={2000} onChange={(event) => setPoolCapacityReason(event.target.value)} required={poolCapacityChanged} rows={2} value={poolCapacityReason} /></label></section>}
          {entity === "package" && <label>Required deposit (%)<input max="100" min="0" onChange={(event) => setDepositPercentage(event.target.value)} placeholder="Not configured" readOnly={lockedResortRate !== undefined} step="0.01" type="number" value={depositPercentage} /></label>}
          {entity === "package" && <><label>Schedule mode<select disabled={isResortVenueOnly} value={scheduleMode} onChange={(event) => setScheduleMode(event.target.value)}><option value="admin_assign">Admin assigns schedule</option><option value="customer_select">Customer selects time</option><option value="fixed">Fixed time</option><option value="untimed">No timed schedule</option></select></label>{scheduleMode === "customer_select" && <><label>Opening time<input type="time" value={operatingStart} onChange={(event) => setOperatingStart(event.target.value)} required /></label><label>Closing time<input type="time" value={operatingEnd} onChange={(event) => setOperatingEnd(event.target.value)} required /></label><label>Booking duration (minutes)<input type="number" min="1" step="1" value={durationMinutes} onChange={(event) => setDurationMinutes(event.target.value)} readOnly={isResortVenueOnly} required /></label><small>{isResortVenueOnly ? `Venue Only duration is fixed at ${resortVenueDuration / 60} hours; enter the business-confirmed opening and closing times.` : "Hours are not prefilled. Enter the business-confirmed schedule before enabling timed bookings."}</small></>}</>}
          {entity === "addon" && <label>Compatible services<input onChange={(event) => setCompatibleServices(event.target.value)} placeholder="Catering, Resort" value={compatibleServices} /></label>}
          {entity === "package_variant" && <label className="admin-editor-checkbox"><input checked={hasAircon} onChange={(event) => setHasAircon(event.target.checked)} type="checkbox" /> Air-conditioned</label>}
          <label className="admin-editor-checkbox"><input checked={active} onChange={(event) => setActive(event.target.checked)} type="checkbox" /> Available for new bookings</label>
          {message && <p className="admin-action-message is-error" role="alert">{message}</p>}
          <div className="admin-editor-modal__actions"><button className="admin-quiet-button" onClick={onClose} type="button">Cancel</button><button className="admin-secondary-button" disabled={busy} type="submit">{busy ? "Saving…" : "Save Changes"}</button></div>
        </form>
      </section>
    </div>
  );
}

function CatalogManagement({ section }: { section: "packages" | "addons" | "catering-menu" }) {
  const table = tableBySection[section];
  const [rows, setRows] = useState<Row[]>([]);
  const [state, setState] = useState<LoadState>("loading");
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const [search, setSearch] = useState("");
  const [availability, setAvailability] = useState("All");
  const [sortBy, setSortBy] = useState("name");
  const [page, setPage] = useState(1);
  const [busyId, setBusyId] = useState("");
  const [editing, setEditing] = useState<CatalogEditor | null>(null);
  const [selected, setSelected] = useState<Row | null>(null);
  const pageSize = 12;
  const load = useCallback(async (silent = false) => {
    if (!silent) setState("loading");
    setError("");
    try {
      setRows(await loadAdminRows(section, table));
      setState("ready");
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Catalog records could not be loaded.");
      setState("error");
    }
  }, [section, table]);
  useEffect(() => {
    void load();
    const refresh = () => { void load(true); };
    window.addEventListener("evently-admin-data-changed", refresh);
    const channel = supabase.channel(`admin-catalog-${table}`)
      .on("postgres_changes", { event: "*", schema: "public", table }, refresh)
      .subscribe();
    return () => {
      window.removeEventListener("evently-admin-data-changed", refresh);
      void supabase.removeChannel(channel);
    };
  }, [load, table]);
  const active = (row: Row) => section === "catering-menu"
    ? row.is_available !== false && row.is_active !== false
    : Boolean(first(row, ["is_active"]) ?? true);
  const visible = useMemo(() => rows.filter((row) => {
    const matchesSearch = !search.trim() || JSON.stringify(row).toLowerCase().includes(search.trim().toLowerCase());
    return matchesSearch && (availability === "All" || (availability === "Available" ? active(row) : !active(row)));
  }).sort((left, right) => {
    if (sortBy === "price") return Number(first(left, ["price"]) ?? 0) - Number(first(right, ["price"]) ?? 0);
    if (sortBy === "updated") return String(first(right, ["updated_at", "created_at"]) ?? "").localeCompare(String(first(left, ["updated_at", "created_at"]) ?? ""));
    return String(first(left, ["name"]) ?? "").localeCompare(String(first(right, ["name"]) ?? ""));
  }), [availability, rows, search, sortBy, section]);
  useEffect(() => { setPage(1); }, [availability, search, sortBy]);
  const pageCount = Math.max(1, Math.ceil(visible.length / pageSize));
  const paginated = visible.slice((page - 1) * pageSize, page * pageSize);

  const toggleAvailability = async (row: Row) => {
    const next = !active(row);
    const name = String(first(row, ["name"]) ?? "this item");
    if (!window.confirm(`${next ? "Make" : "Mark"} ${name} ${next ? "available" : "unavailable"} for new bookings? Existing reservations and agreed prices will remain unchanged.`)) return;
    setBusyId(String(row.id));
    setMessage("");
    const patch = section === "catering-menu" ? { is_active: next, is_available: next } : { is_active: next };
    const result = section === "catering-menu"
      ? await supabase.rpc("evently_admin_update_catering_menu_item", { p_id: String(row.id), p_patch: patch })
      : await supabase.rpc("admin_update_evently_catalog", { p_entity: section === "packages" ? "package" : "addon", p_id: String(row.id), p_patch: patch });
    setBusyId("");
    if (result.error) { setMessage(result.error.message); return; }
    setMessage(`${name} is now ${next ? "available" : "unavailable"} for new bookings.`);
    await load(true);
    window.dispatchEvent(new Event("evently-catalog-changed"));
  };

  const retireCatalogItem = async (row: Row) => {
    const name = String(first(row, ["name"]) ?? "this item");
    if (!window.confirm(`Remove ${name} from new bookings? This safely deactivates the catalog record so existing bookings and historical references are preserved.`)) return;
    setBusyId(String(row.id));
    setMessage("");
    const result = section === "catering-menu"
      ? await supabase.rpc("evently_admin_update_catering_menu_item", {
        p_id: String(row.id), p_patch: { is_active: false, is_available: false },
      })
      : await supabase.rpc("admin_update_evently_catalog", {
        p_entity: "addon", p_id: String(row.id), p_patch: { is_active: false },
      });
    setBusyId("");
    if (result.error) { setMessage(result.error.message); return; }
    setMessage(`${name} was deactivated. Historical booking records were preserved.`);
    await load(true);
    window.dispatchEvent(new Event("evently-catalog-changed"));
  };

  if (state === "loading") return <LoadingState />;
  if (state === "error") return <ErrorState message={error} retry={load} />;
  const title = sections.find(([path]) => path === section)?.[1] ?? "Catalog";
  return <>
    <div className="admin-catalog-tools">
      <label className="admin-search"><span>Search {title.toLowerCase()}</span><div><Icon name="search" /><input onChange={(event) => setSearch(event.target.value)} placeholder="Search name, service, category…" value={search} /></div></label>
      <label><span>Availability</span><select onChange={(event) => setAvailability(event.target.value)} value={availability}><option>All</option><option>Available</option><option>Unavailable</option></select></label>
      <label><span>Sort</span><select onChange={(event) => setSortBy(event.target.value)} value={sortBy}><option value="name">Name</option><option value="price">Price</option><option value="updated">Last updated</option></select></label>
      <button className="admin-quiet-button" onClick={() => void load()} type="button"><Icon name="refresh" /> Refresh</button>
    </div>
    {message && <p className="admin-action-message" role="status">{message}</p>}
    <section className="admin-card admin-table-card admin-catalog-table">
      <div className="admin-card-heading"><div><h2>{title}</h2><p>{visible.length} matching catalog record{visible.length === 1 ? "" : "s"}; prices shown in Philippine pesos{section === "catering-menu" ? " per guest" : ""}.</p></div></div>
      {!visible.length ? <div className="admin-empty"><strong>No catalog records found</strong><p>Adjust the search or availability filter.</p></div> : <>
        <div className="admin-table-scroll"><table>
          <thead><tr>{section === "packages" ? <><th>Package / Service</th><th>Service</th><th>Current price</th></> : section === "addons" ? <><th>Add-on</th><th>Compatible services</th><th>Current price</th></> : <><th>Menu item</th><th>Category</th><th>Price per guest</th></>}<th>Availability</th><th>Last updated</th><th>Actions</th></tr></thead>
          <tbody>{paginated.map((row) => {
            const entity: CatalogEntity = section === "packages" ? "package" : section === "addons" ? "addon" : "menu_item";
            const label = String(first(row, ["name"]) ?? "Catalog item");
            return <tr key={String(row.id)}>
              <td data-label={section === "catering-menu" ? "Menu item" : section === "addons" ? "Add-on" : "Package / Service"}><strong>{label}</strong>{section === "packages" && <small>{show(first(row, ["package_category", "category"]))}</small>}</td>
              {section === "packages" ? <td data-label="Service">{show(first(row, ["service_type", "service"]))}</td> : section === "addons" ? <td data-label="Compatible services">{Array.isArray(row.compatible_services) ? row.compatible_services.join(", ") : show(row.compatible_services)}</td> : <td data-label="Category">{show(row.category)}</td>}
              <td data-label="Current price">{money.format(Number(first(row, ["price"]) ?? 0))}</td>
              <td data-label="Availability"><button aria-checked={active(row)} aria-label={`${label} availability`} className={`admin-switch ${active(row) ? "is-on" : ""}`} disabled={busyId === String(row.id)} onClick={() => void toggleAvailability(row)} role="switch" type="button"><i /><span>{active(row) ? "On" : "Off"}</span></button></td>
              <td data-label="Last updated">{show(first(row, ["updated_at", "created_at"]), "updated_at")}</td>
               <td data-label="Actions" onClick={(event) => event.stopPropagation()}><MoreActionsMenu label={label} items={[
                 { label: section === "packages" ? "View Package Details" : section === "addons" ? "View Add-on Details" : "View Menu Item", onSelect: () => setSelected(row) },
                 { label: section === "packages" ? "Edit Package" : section === "addons" ? "Edit Add-on" : "Edit Menu Item", onSelect: () => setEditing({ entity, row }) },
                 ...(section === "packages" ? [{ label: "Edit Price", onSelect: () => setEditing({ entity, row }) }] : []),
                 { label: `${active(row) ? "Deactivate" : "Activate"} for New Bookings`, disabled: busyId === String(row.id), onSelect: () => void toggleAvailability(row) },
                 ...(section === "catering-menu" || section === "addons" ? [{ label: `Delete ${section === "catering-menu" ? "Menu Item" : "Add-on"} (deactivate)`, disabled: busyId === String(row.id), onSelect: () => void retireCatalogItem(row) }] : []),
               ]} /></td>
            </tr>;
          })}</tbody>
        </table></div>
        {visible.length > pageSize && <div className="admin-pagination"><span>Showing {(page - 1) * pageSize + 1}–{Math.min(page * pageSize, visible.length)} of {visible.length}</span><div><button disabled={page === 1} onClick={() => setPage((current) => current - 1)} type="button">Previous</button><b>{page} / {pageCount}</b><button disabled={page === pageCount} onClick={() => setPage((current) => current + 1)} type="button">Next</button></div></div>}
      </>}
    </section>
    {editing && <CatalogEditorDialog editor={editing} onClose={() => setEditing(null)} onSaved={async () => { setMessage("Catalog details saved."); await load(true); }} />}
    {selected && <DetailDrawer onChanged={load} onClose={() => setSelected(null)} onEditCatalog={(entity, row) => setEditing({ entity, row })} row={selected} section={section} title={show(first(selected, ["name", "id"]))} />}
  </>;
}

function PaymentReviewCard({ payment, onReviewed }: { payment: Row; onReviewed?: (payment: Row) => void }) {
  const [signedUrl, setSignedUrl] = useState("");
  const [proofLoading, setProofLoading] = useState(Boolean(first(payment, ["proof_url"])));
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const statusKey = ["verification_status", "status"].find((key) => payment[key] !== null && payment[key] !== undefined) ?? "status";
  const initialStatus = String(payment[statusKey] ?? "").toLowerCase();
  const [status, setStatus] = useState(initialStatus);
  const proofPath = String(first(payment, ["proof_url"]) ?? "");
  const isImage = /\.(jpe?g|png|webp)$/i.test(proofPath);
  const paymentSummary = reservationPaymentSummary(payment);

  useEffect(() => { setStatus(initialStatus); }, [initialStatus, payment.id]);

  useEffect(() => {
    let active = true;
    setSignedUrl("");
    setProofLoading(Boolean(proofPath));
    if (!proofPath) return () => { active = false; };
    void supabase.storage.from("payment-proofs").createSignedUrl(proofPath, 300).then(({ data, error }) => {
      if (!active) return;
      setProofLoading(false);
      if (error) setMessage(error.message);
      else setSignedUrl(data.signedUrl);
    });
    return () => { active = false; };
  }, [proofPath]);

  const review = async (decision: "verified" | "rejected") => {
    if (busy || status !== "pending") return;
    const reason = decision === "rejected"
      ? window.prompt("Enter the reason and what the customer should correct before resubmitting:")?.trim() ?? ""
      : window.prompt("Optional payment review note. Timely non-demo proof covering the 30% deposit automatically confirms the booking when its schedule is valid:")?.trim() ?? "";
    if (decision === "rejected" && !reason) return;
    if (!window.confirm(decision === "verified"
      ? "Accept this submitted receipt for booking review? This verifies the submitted proof only; it does not independently confirm financial settlement."
      : "Reject this payment proof and request a corrected resubmission?")) return;
    setBusy(true);
    setMessage("");
    const { error } = await supabase.rpc("admin_review_payment", {
      p_decision: decision,
      p_payment_id: String(payment.id ?? ""),
      p_reason: reason || null,
    });
    if (error) {
      setBusy(false);
      setMessage(error.message);
      return;
    }
    const reservationId = String(first(payment, ["reservation_id"]) ?? "");
    const [paymentRefresh, reservationRefresh] = await Promise.all([
      supabase.from("payments").select("*").eq("id", payment.id).single(),
      reservationId ? supabase.from("reservations").select("*").eq("id", reservationId).single() : Promise.resolve({ data: null, error: null }),
    ]);
    const refreshedPayment = (paymentRefresh.data as Row | null) ?? payment;
    const refreshedReservation = reservationRefresh.data as Row | null;
    const updated = {
      ...payment,
      ...refreshedPayment,
      [statusKey]: decision,
      rejection_reason: decision === "rejected" ? reason : null,
      review_notes: reason || null,
      reviewed_at: new Date().toISOString(),
      _reservation_total_amount: first(refreshedReservation ?? payment, ["total_amount", "_reservation_total_amount"]),
      _reservation_deposit_amount: first(refreshedReservation ?? payment, ["deposit_amount", "_reservation_deposit_amount"]),
      _reservation_amount_paid: first(refreshedReservation ?? payment, ["amount_paid", "_reservation_amount_paid"]),
      _reservation_remaining_balance: first(refreshedReservation ?? payment, ["remaining_balance", "_reservation_remaining_balance"]),
      _reservation_payment_status: first(refreshedReservation ?? payment, ["payment_status", "_reservation_payment_status"]),
    };
    onReviewed?.(updated);
    setStatus(decision);
    const refreshError = paymentRefresh.error ?? reservationRefresh.error;
    setMessage(refreshError
      ? `${decision === "verified" ? "Payment proof verified" : "Payment proof rejected"}, but refreshed payment details could not be loaded: ${refreshError.message}`
      : decision === "verified" ? "Payment proof verified. A timely sufficient deposit confirms a valid schedule automatically; payment and booking details refreshed." : "Payment proof rejected; the customer may submit corrected proof before the original deadline.");
    window.dispatchEvent(new Event("evently-admin-data-changed"));
    window.dispatchEvent(new Event("evently-customer-bookings-changed"));
    setBusy(false);
  };

  return <article className="admin-payment-review-card">
    <header><div><strong>{show(first(payment, ["reference_number", "id"]))}</strong><small>Verification status: {paymentVerificationLabel(status)}</small><small>{show(first(payment, ["method", "payment_method"]), "method")} · {show(first(payment, ["submitted_at", "created_at"]), "created_at")}</small></div><Value label="verification status" value={paymentVerificationLabel(status)} /></header>
     <dl><div><dt>Reservation</dt><dd>{show(first(payment, ["_reservation_code", "reservation_code", "reservation_id"]))}</dd></div><div><dt>Submitted amount</dt><dd>{show(first(payment, ["amount", "payment_amount"]), "amount")}</dd></div><div><dt>Customer</dt><dd>{show(first(payment, ["_customer_name", "customer_name", "customer_id"]))}</dd></div><div><dt>Demo mode</dt><dd>{payment.demo_mode === true ? "Demo — no actual money transfer" : "Manual payment proof"}</dd></div>{paymentSummary.total > 0 && <><div><dt>Booking payment status</dt><dd>{paymentSummary.label}</dd></div><div><dt>Verified amount</dt><dd>{money.format(paymentSummary.paid)}</dd></div><div><dt>Total booking cost</dt><dd>{money.format(paymentSummary.total)}</dd></div><div><dt>Remaining balance</dt><dd>{money.format(paymentSummary.balance)}</dd></div></>}<div><dt>Reviewed</dt><dd>{first(payment, ["reviewed_at", "verified_at"]) ? `${show(first(payment, ["reviewed_at", "verified_at"]), "created_at")} · ${show(first(payment, ["reviewed_by", "verified_by"]))}` : "Not reviewed"}</dd></div></dl>
    {proofLoading && <p className="admin-payment-proof-missing">Loading private receipt for review…</p>}
    {proofPath && signedUrl && isImage && <a className="admin-payment-proof-preview" href={signedUrl} rel="noreferrer" target="_blank"><img alt="Private payment receipt preview" src={signedUrl} /><span>Open full-size receipt</span></a>}
    {proofPath && signedUrl && !isImage && <a className="admin-proof-button" href={signedUrl} rel="noreferrer" target="_blank">View private receipt</a>}
    {!proofPath && <p className="admin-payment-proof-missing">Receipt proof is missing. This payment cannot be verified.</p>}
    {Boolean(first(payment, ["rejection_reason", "review_notes"])) && <p className="admin-payment-review-note"><strong>Review note:</strong> {show(first(payment, ["rejection_reason", "review_notes"]))}</p>}
    {status === "pending" && <div className="admin-payment-review-actions"><button disabled={busy || proofLoading || !signedUrl || !proofPath || !first(payment, ["reference_number"])} onClick={() => void review("verified")} type="button">{busy ? "Saving…" : proofLoading ? "Loading Receipt…" : "Verify Payment Proof"}</button><button className="is-danger" disabled={busy} onClick={() => void review("rejected")} type="button">Reject / Request Resubmission</button></div>}
    {message && <p className={`admin-action-message ${/failed|error|cannot|denied/i.test(message) ? "is-error" : ""}`} role="status">{message}</p>}
  </article>;
}

function DetailDrawer({ row, section, title, onClose, onChanged, onNavigate, openScheduleEditor = false, openRejectionModal = false, canManageReservations = false, onEditCatalog }: { row: Row; section: string; title: string; onClose: () => void; onChanged?: () => void | Promise<void>; onNavigate?: (path: string) => void; openScheduleEditor?: boolean; openRejectionModal?: boolean; canManageReservations?: boolean; onEditCatalog?: (entity: CatalogEntity, row: Row) => void }) {
  const [actionState, setActionState] = useState<LoadState>("ready");
  const actionStateRef = useRef(actionState);
  actionStateRef.current = actionState;
  const [actionMessage, setActionMessage] = useState("");
  const [relatedPayments, setRelatedPayments] = useState<Row[]>([]);
  const [termsAcceptance, setTermsAcceptance] = useState<Row | null>(null);
  const [termsAcceptanceLoading, setTermsAcceptanceLoading] = useState(false);
  const [relatedPaymentsLoading, setRelatedPaymentsLoading] = useState(false);
  const [relatedActivity, setRelatedActivity] = useState<Row[]>([]);
  const [customerReservations, setCustomerReservations] = useState<Row[]>([]);
  const [customerPayments, setCustomerPayments] = useState<Row[]>([]);
  const [relatedVariants, setRelatedVariants] = useState<Row[]>([]);
  const [scheduleStart, setScheduleStart] = useState(String(first(row, ["start_time"]) ?? "").slice(0, 5));
  const [scheduleEnd, setScheduleEnd] = useState(String(first(row, ["end_time"]) ?? "").slice(0, 5));
  const [scheduleDate, setScheduleDate] = useState(String(first(row, ["reservation_date"]) ?? "").slice(0, 10));
  const [overrideDeadlineLocal, setOverrideDeadlineLocal] = useState("");
  const [scheduleResource, setScheduleResource] = useState(String(first(row, ["resource_key"]) ?? ""));
  const [scheduleResources, setScheduleResources] = useState<ScheduleResourceOption[]>([]);
  const [scheduleResourceError, setScheduleResourceError] = useState("");
  const [scheduleValidation, setScheduleValidation] = useState<Row | null>(null);
  const [scheduleValidationError, setScheduleValidationError] = useState("");
  const [schedulePersisted, setSchedulePersisted] = useState(true);
  const [scheduleEditing, setScheduleEditing] = useState(false);
  const [reservationTab, setReservationTab] = useState("Overview");
  const [rejectionOpen, setRejectionOpen] = useState(false);
  const [rejectionReason, setRejectionReason] = useState("");
  const rejectionDialogRef = useRef<HTMLElement | null>(null);
  const actionLock = useRef(false);
  const linkedCustomerName = first(row, ["customer_name", "_customer_name", "customer_id"]);
  const linkedReservationCode = first(row, ["reservation_code", "id"]);
  const reservationTotalAmount = first(row, ["total_amount"]);
  const reservationDepositAmount = first(row, ["deposit_amount"]);
  const reservationAmountPaid = first(row, ["amount_paid"]);
  const reservationRemainingBalance = first(row, ["remaining_balance"]);
  const reservationPaymentStatus = first(row, ["payment_status"]);
  const loadRelatedPayments = useCallback(async () => {
    if (section !== "reservations" || !row.id) return;
    setRelatedPaymentsLoading(true);
    const { data, error } = await supabase.from("payments").select("*")
      .eq("reservation_id", row.id).order("created_at", { ascending: false });
    setRelatedPaymentsLoading(false);
    if (error) {
      setActionMessage(error.message);
      return;
    }
    setRelatedPayments(((data ?? []) as Row[]).map((payment) => ({
      ...payment,
      _customer_name: linkedCustomerName,
      _reservation_code: linkedReservationCode,
      _reservation_total_amount: reservationTotalAmount,
      _reservation_deposit_amount: reservationDepositAmount,
      _reservation_amount_paid: reservationAmountPaid,
      _reservation_remaining_balance: reservationRemainingBalance,
      _reservation_payment_status: reservationPaymentStatus,
    })));
  }, [linkedCustomerName, linkedReservationCode, reservationAmountPaid, reservationDepositAmount, reservationPaymentStatus, reservationRemainingBalance, reservationTotalAmount, row.id, section]);
  const groups = [
    { label: section === "reservations" ? "Booking overview" : "Record overview", test: /code|status|date|created|updated|id$/i },
    { label: "Customer information", test: /customer|user|profile|email|phone|mobile|name/i },
    { label: "Schedule and venue", test: /start_time|end_time|venue|resource|location|room/i },
    { label: "Service and package details", test: /service|package|guest|menu|addon|venue|request/i },
    { label: "Payment summary", test: /amount|price|total|deposit|balance|payment|method|reference/i },
  ];
  const used = new Set<string>();
  const grouped = groups.map((group) => {
    const entries = Object.entries(row).filter(([key]) => !used.has(key) && group.test.test(key));
    entries.forEach(([key]) => used.add(key));
    return { ...group, entries };
  });
  const remaining = Object.entries(row).filter(([key]) => !used.has(key));
  useEffect(() => { void loadRelatedPayments(); }, [loadRelatedPayments]);
  useEffect(() => {
    if (section !== "reservations" || !row.id) { setTermsAcceptance(null); return; }
    let active = true;
    setTermsAcceptance(null);
    setTermsAcceptanceLoading(true);
    void supabase.from("evently_terms_acceptances")
      .select("accepted,accepted_at,terms_version")
      .eq("reservation_id", row.id)
      .maybeSingle().then(({data}) => {
        if (!active) return;
        setTermsAcceptance((data as Row | null) ?? null);
        setTermsAcceptanceLoading(false);
      });
    return () => { active = false; };
  }, [row.id, section]);
  useEffect(() => {
    if (section !== "reservations" || !row.id) return;
    void Promise.all([
      supabase.from("admin_activity_logs").select("*").eq("entity_id", row.id),
      supabase.from("evently_reservation_override_audit").select("*").eq("reservation_id", row.id),
    ]).then(([activity, overrides]) => {
      const standard = (activity.data ?? []) as Row[];
      const audited: Row[] = ((overrides.data ?? []) as Row[]).map((entry) => ({
        ...entry,
        description: `${String(entry.reason ?? "")}; before ${JSON.stringify(entry.previous_values ?? {})}; after ${JSON.stringify(entry.new_values ?? {})}`,
      }));
      setRelatedActivity([...standard, ...audited].sort((left, right) =>
        Date.parse(String(right.created_at ?? 0)) - Date.parse(String(left.created_at ?? 0))));
    });
  }, [row.id, section]);
  useEffect(() => {
    if (section !== "reservations") return;
    const refresh = () => { void loadRelatedPayments(); };
    window.addEventListener("evently-admin-data-changed", refresh);
    return () => window.removeEventListener("evently-admin-data-changed", refresh);
  }, [loadRelatedPayments, section]);
  useEffect(() => {
    if (section !== "customers" || !row.id) return;
    supabase.from("reservations").select("*").eq("customer_id", row.id).order("created_at", { ascending: false })
      .then(({ data, error }) => {
        if (error) setActionMessage(error.message);
        else setCustomerReservations((data ?? []) as Row[]);
      });
  }, [row.id, section]);
  useEffect(() => {
    if (section !== "customers" || !row.id) return;
    supabase.from("payments").select("*")
      .eq("customer_id", row.id).order("created_at", { ascending: false })
      .then(({ data, error }) => {
        if (error) setActionMessage(error.message);
        else setCustomerPayments((data ?? []) as Row[]);
      });
  }, [row.id, section]);
  const loadVariants = useCallback(async () => {
    if (section !== "packages" || !row.id) return;
    const { data, error } = await supabase.from("package_variants").select("*").eq("package_id", row.id).order("created_at");
    if (error) setActionMessage(error.message);
    else setRelatedVariants((data ?? []) as Row[]);
  }, [row.id, section]);
  useEffect(() => { void loadVariants(); }, [loadVariants]);
  useEffect(() => {
    const refresh = () => { void loadVariants(); };
    window.addEventListener("evently-admin-data-changed", refresh);
    return () => window.removeEventListener("evently-admin-data-changed", refresh);
  }, [loadVariants]);
  const statusKeys = section === "reservations"
    ? ["status"]
    : section === "orders"
      ? ["order_status", "status"]
      : ["verification_status", "status"];
  const [currentStatus, setCurrentStatus] = useState(() => String(first(row, statusKeys) ?? "").toLowerCase());
  const refreshScheduleValidation = useCallback(async () => {
    if (section !== "reservations" || !row.id) return;
    setScheduleValidation(null);
    setScheduleValidationError("");
    const { data, error } = await supabase.rpc("evently_admin_check_reservation_schedule", {
      p_reservation_id: String(row.id),
    });
    if (error) {
      setScheduleValidationError(error.message);
      return;
    }
    setScheduleValidation(data as Row);
  }, [row.id, section]);
  useEffect(() => { void refreshScheduleValidation(); }, [refreshScheduleValidation]);
  const rowPackageCategory = String(first(row, ["package_category"]) ?? "").toLowerCase();
  const rowScheduleMode = String(first(row, ["schedule_mode"]) ?? "").toLowerCase();
  const scheduleFixed = rowScheduleMode === "fixed" || (rowScheduleMode === "timed" && rowPackageCategory === "pool_tour");
  const scheduleRequired = rowScheduleMode !== "untimed";
  const rowResourceMode = String(first(row, ["resource_mode"]) ?? "admin_assign").toLowerCase();
  const rowHasResource = Boolean(first(row, ["resource_key"]));
  const scheduleResourceRequired = rowPackageCategory !== "outside_catering" && (
    ["event_venue", "room"].includes(rowPackageCategory)
    || rowResourceMode === "exclusive"
    || (rowHasResource && rowResourceMode !== "shared_capacity")
  );
  const selectedResource = scheduleResources.find((resource) => resource.value === scheduleResource);
  const effectiveResourceRequired = scheduleValidation
    ? scheduleValidation.resource_required === true
    : scheduleResourceRequired;
  const scheduleResourceVerified = scheduleResources.some((resource) => resource.value === scheduleResource);
  const scheduleComplete = Boolean(scheduleDate && scheduleStart && scheduleEnd && scheduleStart !== scheduleEnd
    && (!effectiveResourceRequired || scheduleResourceVerified));
  const startMinutes = scheduleStart ? Number(scheduleStart.slice(0, 2)) * 60 + Number(scheduleStart.slice(3, 5)) : 0;
  const endMinutes = scheduleEnd ? Number(scheduleEnd.slice(0, 2)) * 60 + Number(scheduleEnd.slice(3, 5)) : 0;
  const durationMinutes = scheduleStart && scheduleEnd ? (endMinutes > startMinutes ? endMinutes - startMinutes : 1440 - startMinutes + endMinutes) : 0;
  const durationLabel = durationMinutes ? `${Math.floor(durationMinutes / 60)}h ${durationMinutes % 60 ? `${durationMinutes % 60}m` : ""}`.trim() : "Not available";
  useEffect(() => {
    const packageName = String(first(row, ["package_name"]) ?? "").toLowerCase();
    const storedStart = String(first(row, ["start_time"]) ?? "").slice(0, 5);
    const storedEnd = String(first(row, ["end_time"]) ?? "").slice(0, 5);
    const fixedFallback = packageName.includes("overnight")
      ? { end: "04:00", start: "19:00" }
      : packageName.includes("night tour")
        ? { end: "22:00", start: "16:00" }
        : packageName.includes("day tour")
          ? { end: "15:00", start: "08:00" }
          : null;
    setCurrentStatus(String(first(row, statusKeys) ?? "").toLowerCase());
    setScheduleStart(storedStart || (scheduleFixed ? fixedFallback?.start ?? "" : ""));
    setScheduleEnd(storedEnd || (scheduleFixed ? fixedFallback?.end ?? "" : ""));
    setScheduleDate(String(first(row, ["reservation_date"]) ?? "").slice(0, 10));
    const paymentDueAt = first(row, ["payment_due_at"]);
    if (paymentDueAt) {
      const parts = new Intl.DateTimeFormat("en-CA", {
        timeZone: "Asia/Manila", year: "numeric", month: "2-digit", day: "2-digit",
        hour: "2-digit", minute: "2-digit", hourCycle: "h23",
      }).formatToParts(new Date(String(paymentDueAt)));
      const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
      setOverrideDeadlineLocal(`${value.year}-${value.month}-${value.day}T${value.hour}:${value.minute}`);
    } else setOverrideDeadlineLocal("");
    setScheduleResource(String(first(row, ["resource_key"]) ?? ""));
    setSchedulePersisted(!scheduleRequired || Boolean(storedStart && storedEnd));
    setScheduleEditing(openScheduleEditor);
  }, [openScheduleEditor, row, scheduleFixed, scheduleRequired, section]);
  useEffect(() => {
    if (openRejectionModal && section === "reservations" && currentStatus === "pending") {
      setRejectionReason("");
      setRejectionOpen(true);
    }
  }, [openRejectionModal, currentStatus, section]);
  useEffect(() => {
    if (!rejectionOpen) return;
    const previousOverflow = document.body.style.overflow;
    const activeElement = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const previouslyFocused = activeElement && activeElement !== document.body && activeElement.isConnected
      ? activeElement
      : document.querySelector<HTMLElement>(".admin-drawer-actions button.is-danger");
    document.body.style.overflow = "hidden";
    const dialog = rejectionDialogRef.current;
    const focusable = () => dialog?.querySelectorAll<HTMLElement>(
      'button:not([disabled]), textarea:not([disabled]), [href], input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'
    );
    focusable()?.[0]?.focus();
    const keepFocusInside = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        if (actionStateRef.current !== "loading") setRejectionOpen(false);
        return;
      }
      if (event.key !== "Tab") return;
      const items = focusable();
      if (!items?.length) return;
      const firstItem = items[0];
      const lastItem = items[items.length - 1];
      if (event.shiftKey && document.activeElement === firstItem) {
        event.preventDefault();
        lastItem.focus();
      } else if (!event.shiftKey && document.activeElement === lastItem) {
        event.preventDefault();
        firstItem.focus();
      }
    };
    document.addEventListener("keydown", keepFocusInside);
    return () => {
      document.body.style.overflow = previousOverflow;
      document.removeEventListener("keydown", keepFocusInside);
      previouslyFocused?.focus();
    };
  }, [rejectionOpen]);
  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent) => {
      if (rejectionOpen) return;
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [onClose, rejectionOpen]);
  useEffect(() => {
    if (section !== "reservations") return;
    let active = true;
    const loadResources = async () => {
      setScheduleResourceError("");
      const { data, error } = await supabase
        .from("evently_resources")
        .select("resource_key,resource_name,resource_type,location_description,is_active")
        .eq("is_active", true)
        .order("resource_name");
      if (error) {
        if (active) setScheduleResourceError(`Resource configuration could not be loaded: ${error.message}. Apply the EVENTLY resource migration, then add the real facilities.`);
        return;
      }
      if (!active) return;
      const packageId = String(first(row, ["package_id"]) ?? "");
      const variantId = String(first(row, ["package_variant_id"]) ?? "");
      const [packageResult, variantResult] = await Promise.all([
        packageId ? supabase.from("packages").select("resource_key,package_category,service_type,name,resource_mode,schedule_mode").eq("id", packageId).maybeSingle() : Promise.resolve({ data: null, error: null }),
        variantId ? supabase.from("package_variants").select("resource_key").eq("id", variantId).maybeSingle() : Promise.resolve({ data: null, error: null }),
      ]);
      if (!active) return;
      const packageData = (packageResult.data ?? {}) as Row;
      const packageCategory = String(first(row, ["package_category"]) ?? first(packageData, ["package_category"]) ?? "").toLowerCase();
      const packageName = String(first(row, ["package_name"]) ?? first(packageData, ["name"]) ?? "").toLowerCase();
      const expectedType = packageCategory === "event_venue"
        ? "venue"
        : packageCategory === "room" || packageName.includes("room")
          ? "room"
          : "";
      const configured = ((data ?? []) as Row[])
        .filter((resource) => !expectedType || String(resource.resource_type ?? "").toLowerCase().includes(expectedType))
        .map((resource) => ({
          label: String(resource.resource_name),
          location: String(resource.location_description ?? ""),
          type: String(resource.resource_type ?? ""),
          value: String(resource.resource_key),
        }));
      setScheduleResources(configured);
      const existingAssignment = String(first(row, ["resource_key"]) ?? "");
      const catalogAssignment = String(first(variantResult.data as Row ?? {}, ["resource_key"]) ?? first(packageResult.data as Row ?? {}, ["resource_key"]) ?? "");
      const preferredAssignment = configured.some((resource) => resource.value === existingAssignment)
        ? existingAssignment
        : configured.some((resource) => resource.value === catalogAssignment) ? catalogAssignment : "";
      setScheduleResource((current) => configured.some((resource) => resource.value === current) ? current : preferredAssignment);
      if (effectiveResourceRequired && !configured.length) {
        setScheduleResourceError(`No active ${expectedType || "physical"} resources are configured. Add the real facility to evently_resources before scheduling this reservation.`);
      }
    };
    void loadResources();
    return () => { active = false; };
  }, [effectiveResourceRequired, row, section]);
  const saveReservationSchedule = async () => {
    if (section !== "reservations" || !canManageReservations || actionState === "loading") return;
    if (!scheduleStart || !scheduleEnd || scheduleStart === scheduleEnd) {
      setActionState("error");
      setActionMessage("Enter distinct start and end times.");
      return;
    }
    if (effectiveResourceRequired && (!scheduleResource || !scheduleResources.some((resource) => resource.value === scheduleResource))) {
      setActionState("error");
      setActionMessage(scheduleResourceError || "Select the verified physical venue or resource before saving.");
      return;
    }
    const overrideReason = window.prompt("Enter the reason for this schedule or resource override:")?.trim() ?? "";
    if (!overrideReason) return;
    setActionState("loading");
    setActionMessage("");
    const { error } = await supabase.rpc("evently_admin_override_reservation", {
      p_action: scheduleResource && scheduleResource !== String(first(row, ["resource_key"]) ?? "") ? "assign_resource" : "reschedule",
      p_reason: overrideReason,
      p_reservation_date: scheduleDate,
      p_payment_due_at: null,
      p_end_time: scheduleEnd,
      p_reservation_id: String(row.id ?? ""),
      p_resource_key: scheduleResource.trim() || null,
      p_start_time: scheduleStart,
    });
    if (error) {
      setActionState("error");
      setActionMessage(error.message);
      return;
    }
    const refreshed = await supabase.from("reservations").select("*").eq("id", row.id).single();
    if (refreshed.error) {
      setActionState("error");
      setActionMessage(refreshed.error.message);
      return;
    }
    const refreshedRow = refreshed.data as Row;
    setScheduleStart(String(first(refreshedRow, ["start_time"]) ?? scheduleStart).slice(0, 5));
    setScheduleEnd(String(first(refreshedRow, ["end_time"]) ?? scheduleEnd).slice(0, 5));
    setScheduleDate(String(first(refreshedRow, ["reservation_date"]) ?? scheduleDate).slice(0, 10));
    setScheduleResource(String(first(refreshedRow, ["resource_key"]) ?? scheduleResource));
    setActionState("ready");
    setSchedulePersisted(true);
    setScheduleEditing(false);
    await refreshScheduleValidation();
    setActionMessage("Reservation schedule saved, conflict-checked, and recorded in the Administrator override audit.");
    await onChanged?.();
    window.dispatchEvent(new Event("evently-admin-data-changed"));
    window.dispatchEvent(new Event("evently-customer-bookings-changed"));
  };
  const savePaymentDeadlineOverride = async () => {
    if (section !== "reservations" || !canManageReservations || actionState === "loading" || !overrideDeadlineLocal) return;
    const action = first(row, ["expired_at"]) ? "reopen_payment" : "extend_payment_deadline";
    const actionLabel = action === "reopen_payment" ? "reopen" : first(row, ["payment_due_at"]) ? "extend" : "start";
    const overrideReason = window.prompt(`Enter the reason to ${actionLabel} this payment deadline:`)?.trim() ?? "";
    if (!overrideReason) return;
    const dueAt = new Date(`${overrideDeadlineLocal}:00+08:00`).toISOString();
    setActionState("loading");
    setActionMessage("");
    const { error } = await supabase.rpc("evently_admin_override_reservation", {
      p_reservation_id: String(row.id ?? ""), p_action: action, p_reason: overrideReason,
      p_payment_due_at: dueAt,
    });
    if (error) {
      setActionState("error");
      setActionMessage(error.message);
      return;
    }
    setActionState("ready");
    setActionMessage("Payment deadline updated and recorded in the Administrator override audit.");
    await onChanged?.();
    window.dispatchEvent(new Event("evently-admin-data-changed"));
    window.dispatchEvent(new Event("evently-customer-bookings-changed"));
  };
  const detailValue = (key: string, value: unknown) => {
    if (section !== "reservations") return value;
    if (key === "status") return currentStatus;
    if (key === "start_time") return scheduleStart;
    if (key === "end_time") return scheduleEnd;
     if (key === "resource_key") return String(first(scheduleValidation ?? {}, ["resource_key"]) ?? scheduleResource);
    return value;
  };
  const mutate = async (action: string, suppliedReason?: string) => {
    if (actionLock.current || actionState === "loading") return;
    if (section === "reservations" && !canManageReservations) {
      setActionState("error");
      setActionMessage("Only an Owner or Admin can change reservation status.");
      return;
    }
    const rejectedReservation = section === "reservations" && action === "rejected";
    const reservationTargetStatus = rejectedReservation
      ? "cancelled"
      : (["completed", "cancelled"] as const).find((status) => status === action) ?? null;
    if (section === "reservations" && !reservationTargetStatus) {
      setActionState("error");
      setActionMessage("Only payment verification confirms a reservation. Use Administrator override actions for schedule changes or cancellation.");
      return;
    }
    let reason: string | null = suppliedReason ?? null;
    if (action === "cancelled" || rejectedReservation) {
      reason = suppliedReason ?? (window.prompt(section === "payments"
        ? "Enter the payment rejection reason:"
        : "Enter the booking rejection or cancellation reason:")?.trim() ?? "");
      if (!reason) return;
    }
    if (suppliedReason === undefined && !window.confirm(`Confirm ${action === "cancelled" ? "reject/cancel" : action} for this ${section.replace(/-/g, " ")} record?`)) {
      return;
    }
    actionLock.current = true;
    setActionState("loading");
    setActionMessage("");
    const id = String(row.id ?? "");
    const request = section === "reservations"
      ? supabase.rpc("admin_transition_reservation", {
        p_reservation_id: id,
        p_status: reservationTargetStatus as BookingStatus,
        p_reason: reservationTargetStatus === "cancelled" ? reason : null,
      })
      : section === "orders"
        ? supabase.rpc("admin_transition_order", { p_order_id: id, p_status: action })
        : supabase.rpc("admin_review_payment", { p_decision: action, p_payment_id: id, p_reason: reason });
    const { error } = await request;
    if (error) {
      actionLock.current = false;
      setActionState("error");
      setActionMessage(section === "reservations"
        ? `Could not ${rejectedReservation ? "reject" : "update"} reservation status: ${error.message}`
        : error.message);
      if (rejectedReservation) setRejectionOpen(true);
      return;
    }
    let savedReservationStatus: string | null = null;
    let refreshMessage = "";
    if (section === "reservations") {
      const refreshed = await supabase.from("reservations").select("*").eq("id", id).single();
      if (refreshed.error) refreshMessage = ` Status saved, but booking details could not be refreshed: ${refreshed.error.message}`;
      else {
        savedReservationStatus = String(first(refreshed.data as Row, ["status"]) ?? "").toLowerCase();
        if (savedReservationStatus !== reservationTargetStatus) {
          refreshMessage = ` Status update returned, but the saved status is “${savedReservationStatus || "unknown"}”. Refresh the booking and verify it.`;
          savedReservationStatus = null;
        }
      }
    }
    actionLock.current = false;
    setActionState(refreshMessage ? "error" : "ready");
    if (savedReservationStatus) setCurrentStatus(savedReservationStatus);
    else if (section === "reservations") setCurrentStatus(reservationTargetStatus as BookingStatus);
    else setCurrentStatus(action.toLowerCase());
    setActionMessage(section === "reservations"
      ? `${rejectedReservation ? "Reservation rejected and recorded as cancelled" : `Reservation marked ${reservationTargetStatus}`}.${refreshMessage}`
      : "Saved to Supabase.");
    if (rejectedReservation) {
      setRejectionOpen(false);
      setRejectionReason("");
    }
    window.dispatchEvent(new Event("evently-admin-data-changed"));
    window.dispatchEvent(new Event("evently-customer-bookings-changed"));
    await onChanged?.();
  };
  return (
      <div className={`admin-drawer-wrap${rejectionOpen ? " is-confirming-rejection" : ""}`} inert={rejectionOpen}>
      <button aria-label="Close details" className="admin-drawer-backdrop" onClick={onClose} type="button" />
      <aside aria-label={`${title} details`} aria-modal="true" className="admin-detail-drawer" role="dialog">
        <div className="admin-drawer-heading"><div><span>{sections.find(([path]) => path === section)?.[1]} details</span><h2>{title}</h2></div><button aria-label="Close details" onClick={onClose} type="button">Close</button></div>
         {[...grouped, { label: "Additional information", test: /.*/, entries: remaining }].filter((group) => group.entries.length).map((group) => <section className="admin-detail-section" key={group.label}><h3>{group.label}</h3><dl>{group.entries.map(([key, value]) => <div key={key}><dt>{key.replace(/_/g, " ")}</dt><dd><Value label={key} value={detailValue(key, value)} /></dd></div>)}</dl></section>)}
           {section === "reservations" && <section className="admin-detail-section"><h3>Terms and Conditions agreement</h3><dl><div><dt>Status</dt><dd>{termsAcceptanceLoading ? "Checking…" : termsAcceptance?.accepted === true ? "Accepted" : "Not recorded"}</dd></div><div><dt>Terms version</dt><dd>{String(termsAcceptance?.terms_version ?? "—")}</dd></div><div><dt>Accepted at</dt><dd>{termsAcceptance?.accepted_at ? new Intl.DateTimeFormat("en-PH", {dateStyle:"medium",timeStyle:"short",timeZone:"Asia/Manila"}).format(new Date(String(termsAcceptance.accepted_at))) : "—"}</dd></div></dl></section>}
           {section === "reservations" && <CateringChangeRequestsPanel canManage={canManageReservations} onChanged={onChanged} requests={Array.isArray(row._catering_change_requests) ? row._catering_change_requests as Row[] : []} />}
           {section === "reservations" && row.cottage_selected === true && <section className="admin-detail-section"><h3>Selected add-ons</h3><dl><div><dt>Cottage</dt><dd>{money.format(Number(row.cottage_fee ?? 0))}</dd></div></dl></section>}
           {section === "reservations" && <section className="admin-detail-section"><h3>Assigned venue</h3><p><strong>{String(first(scheduleValidation ?? {}, ["resource_name"]) ?? selectedResource?.label ?? first(row, ["resource_name", "resource_key"]) ?? "No physical venue required")}</strong>{selectedResource?.location ? ` · ${selectedResource.location}` : ""}</p>{currentStatus === "pending" && effectiveResourceRequired && <button className="admin-secondary-action" disabled={actionState === "loading"} onClick={() => setScheduleEditing(true)} type="button">Change Venue / Schedule</button>}</section>}
          {section === "reservations" && currentStatus === "pending" && <section className="admin-detail-section"><h3>Audited schedule override</h3><p>Schedule changes require a reason, are checked against concurrent reservations, and are recorded for the Administrator.</p><label><span>New reservation date</span><input onChange={(event) => { setScheduleDate(event.target.value); setSchedulePersisted(false); }} type="date" value={scheduleDate} /></label><button className="admin-secondary-action" disabled={actionState === "loading"} onClick={() => setScheduleEditing(true)} type="button">Edit schedule and resource</button></section>}
          {section === "reservations" && <section className="admin-detail-section"><h3>Payment deadline · Asia/Manila</h3><p>{first(row, ["payment_due_at"]) ? new Intl.DateTimeFormat("en-PH", { timeZone: "Asia/Manila", dateStyle: "medium", timeStyle: "short" }).format(new Date(String(first(row, ["payment_due_at"])))) : "Legacy booking — no automatic deadline until an Administrator starts one"}</p><label><span>{first(row, ["expired_at"]) ? "Reopen until" : first(row, ["payment_due_at"]) ? "Extend until" : "Start deadline until"} (Manila time)</span><input onChange={(event) => setOverrideDeadlineLocal(event.target.value)} type="datetime-local" value={overrideDeadlineLocal} /></label><button className="admin-secondary-action" disabled={actionState === "loading" || !overrideDeadlineLocal || (!first(row, ["expired_at"]) && currentStatus !== "pending")} onClick={() => void savePaymentDeadlineOverride()} type="button">{first(row, ["expired_at"]) ? "Reopen Payment Hold" : first(row, ["payment_due_at"]) ? "Extend Payment Deadline" : "Start 24-Hour Deadline"}</button></section>}
          {section === "reservations" && currentStatus === "confirmed" && <section className="admin-detail-section"><h3>Confirmed schedule override</h3>{!scheduleEditing ? <button className="admin-secondary-action" disabled={actionState === "loading"} onClick={() => setScheduleEditing(true)} type="button">Reschedule / Reassign Resource</button> : <><label><span>New reservation date</span><input onChange={(event) => { setScheduleDate(event.target.value); setSchedulePersisted(false); }} type="date" value={scheduleDate} /></label><label><span>Physical resource</span><select onChange={(event) => { setScheduleResource(event.target.value); setSchedulePersisted(false); }} value={scheduleResource}><option value="">No resource change</option>{scheduleResources.map((resource) => <option key={resource.value} value={resource.value}>{resource.label}</option>)}</select></label><div><label><span>Start time</span><input disabled={scheduleFixed} onChange={(event) => { setScheduleStart(event.target.value); setSchedulePersisted(false); }} type="time" value={scheduleStart} /></label><label><span>End time</span><input disabled={scheduleFixed} onChange={(event) => { setScheduleEnd(event.target.value); setSchedulePersisted(false); }} type="time" value={scheduleEnd} /></label></div><button disabled={actionState === "loading" || !scheduleDate || !scheduleStart || !scheduleEnd} onClick={() => void saveReservationSchedule()} type="button">Save audited override</button><button className="admin-close-action" onClick={() => setScheduleEditing(false)} type="button">Cancel</button></>}</section>}
         {section === "reservations" && <section className="admin-detail-section"><h3>Staff recommendation</h3>{row._latest_staff_recommendation && typeof row._latest_staff_recommendation === "object" ? (() => { const recommendation = row._latest_staff_recommendation as Row; return <dl><div><dt>Recommendation</dt><dd>{show(first(recommendation, ["recommendation"]))}</dd></div><div><dt>Status</dt><dd>{show(first(recommendation, ["review_state"]))}</dd></div><div><dt>Staff member</dt><dd>{show(first(recommendation, ["staff_name", "staff_id"]))}</dd></div><div><dt>Reason</dt><dd>{show(first(recommendation, ["reason"]))}</dd></div><div><dt>Notes</dt><dd>{show(first(recommendation, ["notes"]))}</dd></div><div><dt>Submitted</dt><dd>{show(first(recommendation, ["created_at"]), "created_at")}</dd></div></dl>; })() : <p>No staff recommendation has been submitted for this reservation.</p>}</section>}
        {section === "reservations" && <section className="admin-detail-section"><h3>Payment submissions</h3>{relatedPaymentsLoading ? <p>Loading linked payment submissions…</p> : relatedPayments.length ? <div className="admin-payment-review-list">{relatedPayments.map((payment) => <PaymentReviewCard key={String(payment.id)} onReviewed={(updated) => setRelatedPayments((current) => current.map((item) => item.id === updated.id ? updated : item))} payment={payment} />)}</div> : <p>No payment proof has been submitted for this reservation.</p>}</section>}
        {section === "reservations" && <section className="admin-detail-section"><h3>Reservation history</h3>{relatedActivity.length ? <div className="admin-history-timeline">{relatedActivity.map((activity) => <div key={String(activity.id)}><i /><span><strong>{show(first(activity, ["action"]))}</strong><small>{show(first(activity, ["description"]))}</small><time>{show(first(activity, ["created_at"]), "created_at")}</time></span></div>)}</div> : <p>No administrative history has been recorded for this reservation yet.</p>}</section>}
          {section === "reservations" && currentStatus === "pending" && <section className="admin-approval-checklist"><div><span>Automatic schedule reservation</span><strong>{scheduleValidation?.no_conflict === true && scheduleValidation?.schedule_complete === true ? "Reserved" : "Needs schedule review"}</strong></div>{scheduleValidationError && <small className="admin-schedule-error">Schedule validation unavailable: {scheduleValidationError}</small>}<small>The schedule is reserved when the booking is created. Payment verification automatically confirms eligible bookings; no separate schedule approval is required.</small></section>}
        {section === "reservations" && currentStatus === "pending" && scheduleEditing && <section className="admin-workflow-actions admin-schedule-editor"><h3>Edit schedule</h3><p>{scheduleFixed ? "This package uses a fixed tour schedule. Times are locked to the configured package." : "Assign the agreed schedule. An end time earlier than the start time is treated as the following day."}</p><div className="admin-schedule-context"><span>Reservation</span><strong>{show(first(row, ["reservation_code", "id"]))}</strong><span>Package</span><strong>{show(first(row, ["package_name", "package_id"]))}</strong><span>Variant</span><strong>{show(first(row, ["package_variant", "package_variant_id"]))}</strong><span>Duration</span><strong>{durationLabel}</strong></div><label><span>Reservation date</span><input disabled type="date" value={scheduleDate} /></label>{effectiveResourceRequired ? <label><span>Physical venue or resource</span><select required onChange={(event) => { setScheduleResource(event.target.value); setSchedulePersisted(false); }} value={scheduleResource}><option value="">Select a configured resource</option>{scheduleResources.map((resource) => <option key={resource.value} value={resource.value}>{resource.label}{resource.location ? ` · ${resource.location}` : ""}</option>)}</select></label> : <p className="admin-schedule-shared">No exclusive Evently resource is required for this package.</p>}{scheduleResourceError && <p className="admin-schedule-error" role="alert">{scheduleResourceError}</p>}<div><label><span>Start time</span><input disabled={scheduleFixed} onChange={(event) => { setScheduleStart(event.target.value); setSchedulePersisted(false); }} type="time" value={scheduleStart} /></label><label><span>End time</span><input disabled={scheduleFixed} onChange={(event) => { setScheduleEnd(event.target.value); setSchedulePersisted(false); }} type="time" value={scheduleEnd} /></label></div><div className="admin-schedule-actions"><button className="admin-secondary-action" disabled={actionState === "loading"} onClick={() => { setScheduleStart(String(first(row, ["start_time"]) ?? scheduleStart).slice(0, 5)); setScheduleEnd(String(first(row, ["end_time"]) ?? scheduleEnd).slice(0, 5)); setScheduleResource(String(first(row, ["resource_key"]) ?? "")); setSchedulePersisted(true); setScheduleEditing(false); }} type="button">Cancel</button>{scheduleResourceRequired && <button disabled={actionState === "loading" || Boolean(scheduleResourceError) || !scheduleResource || !scheduleStart || !scheduleEnd} onClick={() => void saveReservationSchedule()} type="button">{actionState === "loading" ? "Saving…" : "Save Schedule"}</button>}</div></section>}
         {section === "reservations" && <section className="admin-workflow-actions admin-drawer-actions"><h3>Reservation actions</h3><p>Schedule assignment happens automatically when the booking is accepted. A sufficient verified deposit confirms the booking.</p><div>{currentStatus === "pending" && <button className="admin-secondary-action" disabled={actionState === "loading"} onClick={() => setScheduleEditing(true)} type="button">Edit Schedule</button>}{currentStatus === "pending" && <button className="is-danger" disabled={actionState === "loading"} onClick={() => { setRejectionReason(""); setRejectionOpen(true); }} type="button">Reject Booking</button>}{currentStatus === "confirmed" && <button disabled={actionState === "loading"} onClick={() => void mutate("completed")} type="button">Mark Completed</button>}{["pending", "confirmed"].includes(currentStatus) && <button className="is-danger" disabled={actionState === "loading"} onClick={() => void mutate("cancelled")} type="button">Cancel / Release Schedule</button>}<button className="admin-close-action" onClick={onClose} type="button">Close</button></div></section>}
         {rejectionOpen && typeof document !== "undefined" && createPortal(
           <div className="admin-modal-wrap admin-rejection-modal-wrap">
             <button aria-label="Close rejection confirmation" className="admin-modal-backdrop" disabled={actionState === "loading"} onClick={() => setRejectionOpen(false)} type="button" />
             <section aria-labelledby="reject-booking-title" aria-modal="true" className="admin-editor-modal admin-rejection-dialog" ref={rejectionDialogRef} role="dialog" tabIndex={-1}>
               <div className="admin-editor-modal__heading"><div><h2 id="reject-booking-title"><i aria-hidden="true">⚠</i> Reject Reservation</h2><span>Reservation {show(linkedReservationCode)}</span></div><button aria-label="Close rejection confirmation" className="admin-rejection-close" disabled={actionState === "loading"} onClick={() => setRejectionOpen(false)} type="button">×</button></div>
               <p className="admin-rejection-customer">Reject this reservation for <strong>{show(linkedCustomerName)}</strong>? This action cannot be undone.</p>
               <label className="admin-rejection-reason"><span>Rejection reason <b aria-hidden="true">*</b></span><textarea autoFocus onChange={(event) => setRejectionReason(event.target.value)} required value={rejectionReason} /></label>
               {actionState === "error" && actionMessage && <p className="admin-action-message is-error" role="alert">{actionMessage}</p>}
               <div className="admin-editor-modal__actions"><button className="admin-quiet-button" disabled={actionState === "loading"} onClick={() => setRejectionOpen(false)} type="button">Cancel</button><button className="admin-secondary-button admin-rejection-confirm" disabled={actionState === "loading" || rejectionReason.trim().length < 3} onClick={() => void mutate("rejected", rejectionReason.trim())} type="button">{actionState === "loading" ? "Rejecting…" : "Confirm Rejection"}</button></div>
             </section>
           </div>,
           document.body
         )}
        {section === "orders" && String(row.order_kind ?? "") === "custom_food" && <section className="admin-detail-section admin-food-order-detail">
          <h3>Customized Food Order</h3>
          <dl>
            <div><dt>Fulfillment</dt><dd>{show(row.fulfillment_method)}</dd></div>
            <div><dt>Requested date</dt><dd>{show(row.event_date,"event_date")}</dd></div>
            <div><dt>Requested time</dt><dd>{String(row.requested_time ?? "To be confirmed").slice(0,5)}</dd></div>
            <div><dt>Customer</dt><dd>{show(first(row,["customer_name","_customer_name"]))}</dd></div>
            <div><dt>Contact</dt><dd>{show(row.customer_phone)}</dd></div>
            {Boolean(row.delivery_address) && typeof row.delivery_address === "object" && (()=>{const address=row.delivery_address as Row;return <div><dt>Delivery address</dt><dd>{[address.street,"Brgy. "+String(address.barangay??""),address.city,"Metro Manila"].filter(Boolean).join(", ")}</dd></div>})()}
            <div><dt>Payment</dt><dd>{show(row.payment_status)} · {money.format(Number(row.remaining_balance??0))} balance</dd></div>
          </dl>
          <h3>Selected dishes, desserts and drinks</h3>
          <div className="admin-food-line-items">{(Array.isArray(row._food_items)?row._food_items as Row[]:[]).map(item=><div key={String(item.id)}>
            <span><strong>{show(item.item_name)}</strong><small>{show(item.category)} · {show(item.quantity)} × {money.format(Number(item.unit_price??0))}</small></span>
            <b>{money.format(Number(item.line_total??0))}</b>
          </div>)}</div>
          <p>Food order payments and any delivery charges are subject to Venice confirmation. Prices per tray were fixed when the order was created.</p>
        </section>}
        {section === "orders" && <section className="admin-workflow-actions"><h3>Order actions</h3><div>{currentStatus === "pending" && <button disabled={actionState === "loading"} onClick={() => void mutate("confirmed")} type="button">Confirm Order</button>}{currentStatus === "confirmed" && <button disabled={actionState === "loading"} onClick={() => void mutate("preparing")} type="button">Start Preparing</button>}{currentStatus === "preparing" && <button disabled={actionState === "loading"} onClick={() => void mutate("ready")} type="button">Mark Ready</button>}{currentStatus === "ready" && <button disabled={actionState === "loading"} onClick={() => void mutate("completed")} type="button">Mark Completed</button>}{!["cancelled", "completed"].includes(currentStatus) && <button className="is-danger" disabled={actionState === "loading"} onClick={() => void mutate("cancelled")} type="button">Cancel Order</button>}</div></section>}
        {section === "payments" && <section className="admin-detail-section"><h3>Payment review</h3><PaymentReviewCard onReviewed={(updated) => { setCurrentStatus(String(first(updated, statusKeys) ?? "").toLowerCase()); void onChanged?.(); }} payment={row} /></section>}
        {section === "packages" && <section className="admin-detail-section"><h3>Package variants</h3>{relatedVariants.length ? <dl>{relatedVariants.map((variant) => <div key={String(variant.id)}><dt>{show(first(variant, ["name"]))}</dt><dd>{show(first(variant, ["price"]), "price")} · {show(first(variant, ["guest_capacity"]))} guests · {first(variant, ["has_aircon"]) ? "Air-conditioned" : "Non-aircon"} <MoreActionsMenu label={String(first(variant, ["name"]) ?? "variant")} items={[{ label: "Edit Variant", disabled: !onEditCatalog, onSelect: () => onEditCatalog?.("package_variant", variant) }]} /></dd></div>)}</dl> : <p>No variants are linked to this package.</p>}</section>}
         {section === "customers" && <section className="admin-detail-section"><h3>Booking history</h3>{customerReservations.length ? <div className="admin-customer-bookings">{customerReservations.map((reservation) => <div key={String(reservation.id)}><span><strong>{show(first(reservation, ["reservation_code", "id"]))}</strong><small>{show(first(reservation, ["package_name", "service_type"]))}</small></span><time>{show(first(reservation, ["reservation_date"]), "reservation_date")}</time><Value label="status" value={first(reservation, ["status"])} /></div>)}</div> : <p>This customer has no reservation records visible under the current RLS policy.</p>}</section>}
         {section === "customers" && <section className="admin-detail-section"><h3>Payment history</h3>{customerPayments.length ? <div className="admin-customer-bookings">{customerPayments.map((payment) => <div key={String(payment.id)}><span><strong>{show(first(payment, ["reference_number", "id"]))}</strong><small>{show(first(payment, ["method"]))} · {show(first(payment, ["created_at"]), "created_at")}</small></span><strong>{show(first(payment, ["amount"]), "amount")}</strong><Value label="status" value={first(payment, ["verification_status", "status"])}/></div>)}</div> : <p>No payment history is visible for this customer under the current RLS policy.</p>}</section>}
        {actionMessage && <p className={`admin-action-message ${actionState === "error" ? "is-error" : ""}`} role="status">{actionMessage}</p>}
      </aside>
    </div>
  );
}

type OverviewData = { reservations: Row[]; orders: Row[]; profiles: Row[]; payments: Row[]; reviews: Row[] };

function Overview({ go }: { go: (path: string) => void }) {
  const [data, setData] = useState<OverviewData | null>(null);
  const [error, setError] = useState("");
  const [trendRange, setTrendRange] = useState<"7" | "30" | "90" | "custom">("30");
  const [customFrom, setCustomFrom] = useState("");
  const [customTo, setCustomTo] = useState("");
  const load = useCallback(async () => {
    setData(null); setError("");
    const names = ["reservations", "orders", "profiles", "payments", "reviews"] as const;
    const results = await Promise.all(names.map((name) => supabase.from(name).select("*").limit(1000)));
    const failure = results.find((result) => result.error)?.error;
    if (failure) { setError(failure.message); return; }
    setData(Object.fromEntries(names.map((name, index) => [name, results[index].data ?? []])) as OverviewData);
  }, []);
  useEffect(() => {
    void load();
    const refresh = () => { void load(); };
    window.addEventListener("evently-admin-data-changed", refresh);
    return () => window.removeEventListener("evently-admin-data-changed", refresh);
  }, [load]);
  if (error) return <ErrorState message={error} retry={load} />;
  if (!data) return <LoadingState />;

  const status = (row: Row) => String(first(row, ["status"]) ?? "").toLowerCase();
  const verified = data.payments.filter((row) => row.demo_mode !== true && String(first(row, ["verification_status", "payment_status", "status"]) ?? "").toLowerCase() === "verified");
  const revenue = verified.reduce((sum, row) => sum + Number(first(row, ["amount", "payment_amount"]) ?? 0), 0);
  const todayKey = new Date().toLocaleDateString("en-CA");
  const todaysBookings = data.reservations.filter((row) => String(first(row, ["reservation_date"]) ?? "").slice(0, 10) === todayKey);
  const pendingReservations = data.reservations.filter((row) => status(row) === "pending");
  const pendingPayments = data.payments.filter((row) => String(first(row, ["verification_status", "payment_status", "status"]) ?? "").toLowerCase() === "pending");
  const missingSchedule = pendingReservations.filter((row) => !first(row, ["start_time"]) || !first(row, ["end_time"]));
  const missingResource = pendingReservations.filter((row) => String(first(row, ["resource_mode"]) ?? "exclusive") !== "shared_capacity" && !first(row, ["resource_key"]));
  const cards = [
    ["Total Bookings", data.reservations.length, "All bookings on record", "reservations", "calendar"],
    ["Revenue", money.format(revenue), "Verified non-demo payments only", "payments", "chart"],
    ["Pending Reservations", pendingReservations.length, "Awaiting review and approval", "reservations", "clock"],
    ["Total Customers", data.profiles.length, "Customer accounts on record", "customers", "users"],
  ];
  const secondaryCards = [
    ["Confirmed Reservations", data.reservations.filter((row) => status(row) === "confirmed").length, "Upcoming confirmed bookings", "reservations", "star"],
    ["Today's Schedule", todaysBookings.length, "Bookings scheduled today", "calendar", "calendar"],
    ["Pending Payments", pendingPayments.length, "Awaiting secure verification", "payments", "card"],
  ];
  const months = Array.from({ length: 6 }, (_, offset) => {
    const current = new Date();
    current.setDate(1);
    current.setMonth(current.getMonth() - (5 - offset));
    return current;
  });
  const dateFor = (row: Row) => {
    const value = first(row, ["reservation_date", "event_date", "submitted_at", "created_at"]);
    return value && !Number.isNaN(Date.parse(String(value))) ? new Date(String(value)) : null;
  };
  const analyticsEnd = trendRange === "custom" && customTo ? new Date(`${customTo}T23:59:59`) : new Date();
  const analyticsStart = trendRange === "custom" && customFrom
    ? new Date(`${customFrom}T00:00:00`)
    : new Date(analyticsEnd.getFullYear(), analyticsEnd.getMonth(), analyticsEnd.getDate() - Number(trendRange === "custom" ? 30 : trendRange) + 1);
  const analyticsReservations = data.reservations.filter((row) => {
    const value = dateFor(row);
    return value && value >= analyticsStart && value <= analyticsEnd;
  });
  const rangeDays = Math.max(1, Math.ceil((analyticsEnd.getTime() - analyticsStart.getTime()) / 86400000) + 1);
  const bucketSize = Math.max(1, Math.ceil(rangeDays / 30));
  const trendBuckets = Array.from({ length: Math.ceil(rangeDays / bucketSize) }, (_, index) => {
    const start = new Date(analyticsStart);
    start.setDate(start.getDate() + index * bucketSize);
    const end = new Date(start);
    end.setDate(end.getDate() + bucketSize);
    return {
      label: start.toLocaleDateString("en-PH", { day: "numeric", month: "short" }),
      value: analyticsReservations.filter((row) => {
        const itemDate = dateFor(row);
        return itemDate && itemDate >= start && itemDate < end;
      }).length,
    };
  });
  const maxTrend = Math.max(...trendBuckets.map((item) => item.value), 1);
  const trendCoordinates = trendBuckets.map((item, index) => ({
    ...item,
    x: trendBuckets.length === 1 ? 300 : 24 + index / (trendBuckets.length - 1) * 552,
    y: 158 - item.value / maxTrend * 124,
  }));
  const trendLine = trendCoordinates.map((item, index) => `${index ? "L" : "M"}${item.x},${item.y}`).join(" ");
  const trendArea = trendCoordinates.length ? `${trendLine} L${trendCoordinates[trendCoordinates.length - 1].x},170 L${trendCoordinates[0].x},170 Z` : "";
  const monthKey = (value: Date) => `${value.getFullYear()}-${value.getMonth()}`;
  const revenueSeries = months.map((month) => verified.filter((row) => {
    const value = dateFor(row);
    return value && monthKey(value) === monthKey(month);
  }).reduce((sum, row) => sum + Number(first(row, ["amount", "payment_amount"]) ?? 0), 0));
  const maxRevenue = Math.max(...revenueSeries, 1);
  const classifyService = (row: Row) => {
    const combined = `${String(first(row, ["service_type", "service", "service_category"]) ?? "")} ${String(first(row, ["package_name", "package_category"]) ?? "")}`.toLowerCase();
    if (combined.includes("catering")) return "Catering";
    if (combined.includes("room") || combined.includes("accommodation") || combined.includes("kubo")) return "Room Accommodation";
    if (combined.includes("venue") || combined.includes("event")) return "Event Venue";
    return "Resort / Swimming Pool";
  };
  const popularServices = analyticsReservations.reduce<Record<string, number>>((totals, row) => {
    const service = classifyService(row);
    totals[service] = (totals[service] ?? 0) + 1;
    return totals;
  }, {});
  const maxService = Math.max(...Object.values(popularServices), 1);
  const statusItems = ["pending", "confirmed", "completed", "cancelled"].map((name) => ({
    count: analyticsReservations.filter((row) => status(row) === name).length,
    name,
  }));
  const statusTotal = Math.max(analyticsReservations.length, 1);
  let statusOffset = 0;
  const statusSegments = statusItems.map((item) => {
    const length = item.count / statusTotal * 100;
    const segment = { ...item, length, offset: -statusOffset };
    statusOffset += length;
    return segment;
  });
  const upcomingLimit = new Date();
  upcomingLimit.setDate(upcomingLimit.getDate() + 7);
  const upcoming = data.reservations.filter((row) => {
    const value = dateFor(row);
    return value && value >= new Date() && value <= upcomingLimit && !["cancelled", "completed"].includes(status(row));
  });
  const attentionRecords = [
    ...pendingReservations.map((row) => ({ action: "Review booking", detail: "Waiting for approval", icon: "clock", path: `reservations?record=${row.id}`, row })),
    ...missingSchedule.map((row) => ({ action: "Set schedule", detail: "Missing start or end time", icon: "calendar", path: `reservations?record=${row.id}`, row })),
    ...missingResource.map((row) => ({ action: "Assign venue", detail: "Missing physical resource", icon: "pin", path: `reservations?record=${row.id}`, row })),
    ...pendingPayments.map((row) => ({ action: "Verify payment", detail: "Payment awaiting verification", icon: "card", path: `payments?record=${row.id}`, row })),
    ...upcoming.map((row) => ({ action: "View booking", detail: "Upcoming within seven days", icon: "calendar", path: `reservations?record=${row.id}`, row })),
  ].filter((item, index, items) => items.findIndex((candidate) => candidate.path === item.path && candidate.detail === item.detail) === index).slice(0, 7);
  const recent = (rows: Row[], count = 4) => [...rows].sort((a, b) => {
    const aDate = dateFor(a)?.getTime() ?? 0;
    const bDate = dateFor(b)?.getTime() ?? 0;
    return bDate - aDate;
  }).slice(0, count);
  return (
    <>
      <div className="admin-stat-grid admin-overview-stats">{cards.map(([label, value, description, path, icon]) => <button key={label} onClick={() => go(String(path))} type="button"><i><Icon name={String(icon)} /></i><span>{label}</span><strong>{value}</strong><small>{description}</small></button>)}</div>
      <div className="admin-chart-grid admin-overview-charts">
        <section className="admin-card admin-chart-card admin-trend-card"><div className="admin-card-heading"><div><h2>Reservation trends</h2><p>Actual booking volume during the selected period.</p></div><div className="admin-chart-range">{(["7", "30", "90", "custom"] as const).map((item) => <button className={trendRange === item ? "is-active" : ""} key={item} onClick={() => setTrendRange(item)} type="button">{item === "custom" ? "Custom" : `${item} days`}</button>)}</div></div>{trendRange === "custom" && <div className="admin-chart-custom"><label>From<input onChange={(event) => setCustomFrom(event.target.value)} type="date" value={customFrom} /></label><label>To<input min={customFrom || undefined} onChange={(event) => setCustomTo(event.target.value)} type="date" value={customTo} /></label></div>}
          <div className="admin-line-chart"><svg aria-label="Reservation volume line chart" preserveAspectRatio="none" role="img" viewBox="0 0 600 180"><path className="admin-line-chart__grid" d="M24 34H576M24 76H576M24 118H576M24 160H576" /><path className="admin-line-chart__area" d={trendArea} /><path className="admin-line-chart__line" d={trendLine} />{trendCoordinates.map((item) => <circle cx={item.x} cy={item.y} key={`${item.label}-${item.x}`} r="3.5"><title>{item.label}: {item.value} reservations</title></circle>)}</svg><div>{trendCoordinates.filter((_, index) => index === 0 || index === trendCoordinates.length - 1 || index % Math.max(1, Math.floor(trendCoordinates.length / 4)) === 0).map((item) => <span key={`${item.label}-${item.x}`}>{item.label}</span>)}</div></div>
        </section>
        <section className="admin-card admin-chart-card"><div className="admin-card-heading"><div><h2>Monthly verified revenue</h2><p>Revenue from verified payment records only</p></div></div>
          <div className="admin-column-chart admin-column-chart--revenue">{revenueSeries.map((value, index) => <div key={monthKey(months[index])}><span>{value ? money.format(value) : ""}</span><i><b style={{ height: `${Math.max(4, value / maxRevenue * 100)}%` }} /></i><small>{months[index].toLocaleDateString("en-PH", { month: "short" })}</small></div>)}</div>
        </section>
        <section className="admin-card"><div className="admin-card-heading"><div><h2>Popular services</h2><p>Bookings grouped by operational service.</p></div></div>
          {Object.keys(popularServices).length ? <div className="admin-horizontal-bars">{["Catering", "Resort / Swimming Pool", "Room Accommodation", "Event Venue"].map((name) => { const count = popularServices[name] ?? 0; return <div key={name}><span><strong>{name}</strong><b>{count}</b></span><i><u style={{ width: `${count / maxService * 100}%` }} /></i></div>; })}</div> : <div className="admin-chart-empty">No reservation service data available.</div>}
        </section>
        <section className="admin-card"><div className="admin-card-heading"><div><h2>Booking status distribution</h2><p>Actual reservation statuses in this period.</p></div></div>
          <div className="admin-donut-layout"><div className="admin-donut-chart"><svg aria-label="Booking status donut chart" role="img" viewBox="0 0 140 140"><circle className="admin-donut-track" cx="70" cy="70" r="52" />{statusSegments.map((item) => <circle className={`admin-donut-segment is-${statusTone(item.name)}`} cx="70" cy="70" key={item.name} pathLength="100" r="52" strokeDasharray={`${item.length} ${100 - item.length}`} strokeDashoffset={item.offset}><title>{item.name}: {item.count}</title></circle>)}</svg><span><strong>{analyticsReservations.length}</strong><small>Total</small></span></div><div className="admin-donut-legend">{statusItems.map((item) => <div key={item.name}><i className={`is-${statusTone(item.name)}`} /><span>{item.name}</span><strong>{item.count}</strong></div>)}</div></div>
        </section>
      </div>
      <div className="admin-stat-grid admin-overview-secondary-stats">{secondaryCards.map(([label, value, description, path, icon]) => <button key={label} onClick={() => go(String(path))} type="button"><i><Icon name={String(icon)} /></i><span>{label}</span><strong>{value}</strong><small>{description}</small></button>)}</div>
      <section className="admin-card admin-attention-card">
        <div className="admin-card-heading"><div><span className="admin-section-eyebrow">Requires attention</span><h2>Operational queue</h2><p>Open the exact reservation or payment requiring action.</p></div><b>{attentionRecords.length}</b></div>
        <div className="admin-attention-list">
          {attentionRecords.length ? attentionRecords.map((item, index) => <button key={`${item.path}-${item.detail}-${index}`} onClick={() => go(item.path)} type="button"><i><Icon name={item.icon} /></i><span><strong>{show(first(item.row, ["reservation_code", "_reservation_code", "reference_number", "id"]))}</strong><small>{item.detail} · {show(first(item.row, ["customer_name", "_customer_name", "amount"]))}</small></span><em>{item.action}</em></button>) : <div className="admin-compact-empty">No pending operational actions.</div>}
        </div>
      </section>
      <section className="admin-card admin-dashboard-table">
        <div className="admin-card-heading"><div><h2>Recent reservations</h2><p>Newest customer booking requests.</p></div><button onClick={() => go("reservations")} type="button">View all reservations</button></div>
        <div className="admin-table-scroll"><table><thead><tr><th>Reservation</th><th>Customer</th><th>Service</th><th>Date & time</th><th>Status</th><th>Payment</th><th>Action</th></tr></thead><tbody>{recent(data.reservations, 6).map((row, index) => <tr key={String(row.id ?? index)}><td><strong>{show(first(row, ["reservation_code", "id"]))}</strong></td><td>{show(first(row, ["customer_name", "customer_id"]))}</td><td>{show(first(row, ["service_type", "service"]))}</td><td>{show(first(row, ["reservation_date"]), "reservation_date")}<small>{reservationSchedule(row)}</small></td><td><Value label="status" value={first(row, ["status"])} /></td><td><Value label="payment status" value={first(row, ["payment_status"])} /></td><td><button className="admin-row-action" onClick={() => go(`reservations?record=${row.id}`)} type="button">{status(row) === "pending" ? "Review" : "View"}</button></td></tr>)}</tbody></table></div>
      </section>
      <div className="admin-recent-grid">
        {[
          ["Recent reservations", recent(data.reservations), "reservations", ["reservation_code", "code", "id"], ["service", "service_type", "status"]],
          ["Pending payment verifications", data.payments.filter((row) => String(first(row, ["verification_status", "status"]) ?? "").toLowerCase() === "pending").slice(0, 4), "payments", ["payment_reference", "reference", "id"], ["amount", "payment_amount"]],
          ["Recent activity", recent(data.orders), "orders", ["order_code", "code", "id"], ["order_status", "status"]],
        ].map(([label, rows, path, primaryKeys, secondaryKeys]) => <section className="admin-card admin-recent-card" key={String(label)}><div className="admin-card-heading"><div><h2>{label as string}</h2><p>Latest live records</p></div><button onClick={() => go(String(path))} type="button">View all <Icon name="chevron" /></button></div><div>{(rows as Row[]).length ? (rows as Row[]).map((row, index) => <button key={String(row.id ?? index)} onClick={() => go(String(path))} type="button"><i>{String(label).slice(0, 1)}</i><span><strong>{show(first(row, primaryKeys as string[]))}</strong><small>{show(first(row, secondaryKeys as string[]), (secondaryKeys as string[])[0])}</small></span><Icon name="chevron" /></button>) : <p className="admin-compact-empty">No records found.</p>}</div></section>)}
      </div>
    </>
  );
}

function CalendarView() {
  const [rows, setRows] = useState<Row[]>([]);
  const [error, setError] = useState("");
  const [month, setMonth] = useState(() => new Date());
  const [serviceFilter, setServiceFilter] = useState("All");
  const [statusFilter, setStatusFilter] = useState("All");
  const [view, setView] = useState<"month" | "week" | "day">("month");
  const [selected, setSelected] = useState<Row | null>(null);
  const load = useCallback(async () => {
    setError("");
    try {
      setRows(await loadAdminRows("reservations", "reservations"));
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Reservations could not be loaded.");
    }
  }, []);
  useEffect(() => {
    void load();
    const refresh = () => { void load(); };
    window.addEventListener("evently-admin-data-changed", refresh);
    const channel = supabase.channel("admin-calendar-reservations")
      .on("postgres_changes", { event: "*", schema: "public", table: "reservations" }, () => { void load(); })
      .subscribe();
    return () => {
      window.removeEventListener("evently-admin-data-changed", refresh);
      void supabase.removeChannel(channel);
    };
  }, [load]);
  if (error) return <ErrorState message={error} retry={load} />;
  const firstDay = new Date(month.getFullYear(), month.getMonth(), 1);
  const days = Array.from({ length: 42 }, (_, index) => index - firstDay.getDay() + 1);
  const inMonth = (day: number) => day > 0 && day <= new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate();
  const services = Array.from(new Set(rows.map((row) => String(first(row, ["service", "service_type", "service_category"]) ?? "")).filter(Boolean)));
  const visibleRows = rows.filter((row) =>
    (serviceFilter === "All" || String(first(row, ["service", "service_type", "service_category"]) ?? "") === serviceFilter)
    && (statusFilter === "All" || normalizedStatus(row) === statusFilter.toLowerCase()),
  );
  const calendarDate = (row: Row) => {
    const value = first(row, ["reservation_date", "event_date", "date", "created_at"]);
    return value && !Number.isNaN(Date.parse(String(value))) ? new Date(`${String(value).slice(0, 10)}T00:00:00`) : null;
  };
  const weekStart = new Date(month.getFullYear(), month.getMonth(), month.getDate() - month.getDay());
  weekStart.setHours(0, 0, 0, 0);
  const weekEnd = new Date(weekStart);
  weekEnd.setDate(weekStart.getDate() + 7);
  const periodRows = visibleRows.filter((row) => {
    const value = calendarDate(row);
    if (!value) return false;
    if (view === "day") return value.toDateString() === month.toDateString();
    if (view === "week") return value >= weekStart && value < weekEnd;
    return value.getMonth() === month.getMonth() && value.getFullYear() === month.getFullYear();
  }).sort((a, b) => `${String(first(a, ["reservation_date"]) ?? "")}${String(first(a, ["start_time"]) ?? "")}`.localeCompare(`${String(first(b, ["reservation_date"]) ?? "")}${String(first(b, ["start_time"]) ?? "")}`));
  const onDay = (day: number) => visibleRows.filter((row) => {
    const value = first(row, ["reservation_date", "event_date", "date", "created_at"]);
    if (!value || Number.isNaN(Date.parse(String(value)))) return false;
    const recordDate = new Date(String(value));
    return recordDate.getFullYear() === month.getFullYear() && recordDate.getMonth() === month.getMonth() && recordDate.getDate() === day;
  });
  return (
    <>
      <div className="admin-calendar-toolbar">
        <div><div className="admin-filter-tabs"><button className={serviceFilter === "All" ? "is-active" : ""} onClick={() => setServiceFilter("All")} type="button">All services</button>{services.map((service) => <button className={serviceFilter === service ? "is-active" : ""} key={service} onClick={() => setServiceFilter(service)} type="button">{service}</button>)}</div><div className="admin-filter-tabs"><button className={statusFilter === "All" ? "is-active" : ""} onClick={() => setStatusFilter("All")} type="button">All statuses</button>{["Pending", "Confirmed", "Completed", "Cancelled"].map((item) => <button className={statusFilter === item ? "is-active" : ""} key={item} onClick={() => setStatusFilter(item)} type="button">{item}</button>)}</div></div>
        <div className="admin-calendar-actions"><div className="admin-view-switcher">{(["month", "week", "day"] as const).map((item) => <button aria-pressed={view === item} className={view === item ? "is-active" : ""} key={item} onClick={() => setView(item)} type="button">{item}</button>)}</div><button className="admin-secondary-button" onClick={() => setMonth(new Date())} type="button">Today</button></div>
      </div>
      <section className="admin-card admin-calendar">
        <div className="admin-calendar-heading"><button aria-label={`Previous ${view}`} onClick={() => setMonth((current) => { const next = new Date(current); if (view === "month") next.setMonth(next.getMonth() - 1, 1); else next.setDate(next.getDate() - (view === "week" ? 7 : 1)); return next; })} type="button">Previous</button><h2>{view === "month" ? month.toLocaleDateString("en-PH", { month: "long", year: "numeric" }) : view === "week" ? `${weekStart.toLocaleDateString("en-PH", { month: "short", day: "numeric" })}–${new Date(weekEnd.getTime() - 86400000).toLocaleDateString("en-PH", { month: "short", day: "numeric", year: "numeric" })}` : month.toLocaleDateString("en-PH", { weekday: "long", month: "long", day: "numeric", year: "numeric" })}</h2><button aria-label={`Next ${view}`} onClick={() => setMonth((current) => { const next = new Date(current); if (view === "month") next.setMonth(next.getMonth() + 1, 1); else next.setDate(next.getDate() + (view === "week" ? 7 : 1)); return next; })} type="button">Next</button></div>
        <p className="admin-calendar-note">Calendar entries use live reservation schedules. Exclusive resources are conflict-checked by Supabase; shared pool tours may run concurrently.</p>
        {view === "month" && <><div className="admin-calendar-week">{["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map((day) => <span key={day}>{day}</span>)}</div><div className="admin-calendar-grid">{days.map((day, index) => <div className={!inMonth(day) ? "is-outside" : ""} key={index}><span>{inMonth(day) ? day : ""}</span>{inMonth(day) && onDay(day).slice(0, 3).map((row, rowIndex) => <button className={`is-${statusTone(first(row, ["status"]))}`} key={rowIndex} onClick={() => setSelected(row)} type="button"><strong>{show(first(row, ["service", "service_type", "_kind"]))}</strong><small>{reservationSchedule(row)} · {show(first(row, ["resource_name", "resource_key", "reservation_code"]))} · {show(first(row, ["status"]))}</small></button>)}{inMonth(day) && onDay(day).length > 3 && <small className="admin-calendar-more">+{onDay(day).length - 3} more</small>}</div>)}</div></>}
        <div className={view === "month" ? "admin-calendar-agenda" : "admin-calendar-list"}>{periodRows.length ? periodRows.map((row, index) => <button key={String(row.id ?? index)} onClick={() => setSelected(row)} type="button"><time>{show(first(row, ["reservation_date"]), "reservation_date")}<strong>{reservationSchedule(row)}</strong></time><span><strong>{show(first(row, ["package_name", "service_type"]))}</strong><small>{show(first(row, ["customer_name", "_customer_name"]))} · {show(first(row, ["resource_name", "resource_key"]))}</small></span><Value label="status" value={first(row, ["status"])} /></button>) : <div className="admin-empty"><strong>No scheduled reservations</strong><p>No live bookings match this calendar period and filter.</p></div>}</div>
      </section>
      {selected && <DetailDrawer onChanged={load} onClose={() => setSelected(null)} row={selected} section="reservations" title={show(first(selected, ["reservation_code", "id"]))} />}
    </>
  );
}

function SchemaRequired({ title, tables, children }: { title: string; tables: string; children: ReactNode }) {
  return <section className="admin-card admin-schema-note"><span>Backend dependency</span><h2>{title}</h2><p>{children}</p><code>{tables}</code><p>The dashboard does not create frontend-only records. Apply the separately provided SQL after reviewing it against the production schema.</p></section>;
}

function Reports() {
  const [reservations, setReservations] = useState<Row[]>([]);
  const [payments, setPayments] = useState<Row[]>([]);
  const [state, setState] = useState<LoadState>("loading");
  const [error, setError] = useState("");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const load = useCallback(async () => {
    setState("loading"); setError("");
    const [reservationResult, paymentResult] = await Promise.all([
      supabase.from("reservations").select("*").limit(2000),
      supabase.from("payments").select("*").limit(2000),
    ]);
    const failure = reservationResult.error ?? paymentResult.error;
    if (failure) { setError(failure.message); setState("error"); return; }
    setReservations((reservationResult.data ?? []) as Row[]);
    setPayments((paymentResult.data ?? []) as Row[]);
    setState("ready");
  }, []);
  useEffect(() => { void load(); }, [load]);
  if (state === "loading") return <LoadingState />;
  if (state === "error") return <ErrorState message={error} retry={load} />;
  const withinRange = (row: Row) => {
    const value = String(first(row, ["reservation_date", "submitted_at", "created_at"]) ?? "").slice(0, 10);
    return (!from || value >= from) && (!to || value <= to);
  };
  const scopedReservations = reservations.filter(withinRange);
  const scopedPayments = payments.filter(withinRange);
  const verifiedPayments = scopedPayments.filter((row) => row.demo_mode !== true && /verified|paid/.test(normalizedStatus(row, ["verification_status", "payment_status", "status"])));
  const revenue = verifiedPayments.reduce((sum, row) => sum + Number(first(row, ["amount", "payment_amount"]) ?? 0), 0);
  const serviceTotals = scopedReservations.reduce<Record<string, number>>((totals, row) => {
    const service = String(first(row, ["service_type", "service"]) ?? "Unspecified");
    totals[service] = (totals[service] ?? 0) + 1;
    return totals;
  }, {});
  const paymentSummary = ["pending", "verified", "rejected"].map((name) => ({
    count: scopedPayments.filter((row) => normalizedStatus(row, ["verification_status", "payment_status", "status"]) === name).length,
    name,
  }));
  return (
    <>
      <div className="admin-report-filters"><div><span>Reporting period</span><strong>Live operational data</strong></div><label><span>From</span><input onChange={(event) => setFrom(event.target.value)} type="date" value={from} /></label><label><span>To</span><input min={from || undefined} onChange={(event) => setTo(event.target.value)} type="date" value={to} /></label><button className="admin-quiet-button" onClick={() => { setFrom(""); setTo(""); }} type="button">Clear dates</button></div>
      <div className="admin-stat-grid admin-report-stats">
        <article><i><Icon name="calendar" /></i><span>Total bookings</span><strong>{scopedReservations.length}</strong><small>All reservation statuses</small></article>
        <article><i><Icon name="star" /></i><span>Confirmed bookings</span><strong>{scopedReservations.filter((row) => normalizedStatus(row) === "confirmed").length}</strong><small>Confirmed reservation records</small></article>
        <article><i><Icon name="chart" /></i><span>Revenue collected</span><strong>{money.format(revenue)}</strong><small>Verified non-demo payments only</small></article>
      </div>
      <div className="admin-chart-grid">
        <section className="admin-card"><div className="admin-card-heading"><div><h2>Reservations by service</h2><p>Live service mix for the selected period.</p></div></div>{Object.keys(serviceTotals).length ? <div className="admin-service-list">{Object.entries(serviceTotals).sort((a, b) => b[1] - a[1]).map(([name, count]) => <div key={name}><i>{name.slice(0, 1)}</i><span><strong>{name}</strong><small>{count} booking{count === 1 ? "" : "s"}</small></span><b>{Math.round(count / Math.max(scopedReservations.length, 1) * 100)}%</b></div>)}</div> : <div className="admin-chart-empty">No reservations in this period.</div>}</section>
        <section className="admin-card"><div className="admin-card-heading"><div><h2>Booking status distribution</h2><p>Current status of selected reservations.</p></div></div><div className="admin-bars">{["pending", "confirmed", "completed", "cancelled"].map((name) => { const count = scopedReservations.filter((row) => normalizedStatus(row) === name).length; const width = scopedReservations.length ? count / scopedReservations.length * 100 : 0; return <div key={name}><span><em className={`admin-status-dot admin-status-dot--${statusTone(name)}`} />{name}<b>{count}</b></span><i><u className={`is-${statusTone(name)}`} style={{ width: `${width}%` }} /></i></div>; })}</div></section>
        <section className="admin-card"><div className="admin-card-heading"><div><h2>Payment verification summary</h2><p>Payment review outcomes for the selected period.</p></div></div><div className="admin-payment-summary">{paymentSummary.map((item) => <div key={item.name}><Value label="status" value={item.name} /><strong>{item.count}</strong><small>payment{item.count === 1 ? "" : "s"}</small></div>)}</div></section>
        <section className="admin-card admin-report-note"><span>Revenue policy</span><h2>Demo proofs are excluded from revenue</h2><p>Revenue figures include only verified or paid non-demo payment rows. Demo records may be accepted for booking review, but they do not represent financial settlement and are not counted as revenue.</p></section>
      </div>
    </>
  );
}

function NotificationsView({ go }: { go: (path: string) => void }) {
  const [rows, setRows] = useState<Row[]>([]);
  const [state, setState] = useState<LoadState>("loading");
  const [error, setError] = useState("");
  const [search, setSearch] = useState("");
  const [busyId, setBusyId] = useState("");
  const [actionMessage, setActionMessage] = useState("");
  const load = useCallback(async () => {
    setState("loading"); setError("");
    const { data, error: queryError } = await supabase.from("notifications").select("*").order("created_at", { ascending: false }).limit(500);
    if (queryError) { setError(queryError.message); setState("error"); return; }
    setRows((data ?? []) as Row[]); setState("ready");
  }, []);
  useEffect(() => { void load(); }, [load]);
  if (state === "loading") return <LoadingState />;
  if (state === "error") return <ErrorState message={error} retry={load} />;
  const visible = rows.filter((row) => !search.trim() || JSON.stringify(row).toLowerCase().includes(search.trim().toLowerCase()));
  const markRead = async (ids: string[]) => {
    if (!ids.length || busyId) return;
    setBusyId(ids.length === 1 ? ids[0] : "all");
    setActionMessage("");
    let { error: updateError } = await supabase.rpc("evently_admin_mark_notifications_read", { p_ids: ids });
    if (updateError && isMissingSupabaseRpc(updateError)) {
      // The legacy notification policy restricts this update to Owner/Admin;
      // newer schemas revoke direct writes and expose the RPC above.
      const fallback = await supabase.from("notifications").update({ is_read: true }).in("id", ids);
      updateError = fallback.error;
    }
    setBusyId("");
    if (updateError) { setActionMessage(updateError.message); return; }
    setActionMessage(ids.length === 1 ? "Notification marked as read." : `${ids.length} notifications marked as read.`);
    await load();
  };
  const openLinkedRecord = (row: Row) => {
    const entity = String(first(row, ["entity_type"]) ?? "").toLowerCase();
    const id = String(first(row, ["entity_id"]) ?? "");
    const target = entity.includes("reservation") || entity.includes("booking") ? "reservations"
      : entity.includes("payment") ? "payments"
        : entity.includes("order") ? "orders"
          : entity.includes("customer") || entity.includes("profile") ? "customers" : "";
    if (target && id) go(`${target}?record=${encodeURIComponent(id)}`);
  };
  return (
    <>
      <div className="admin-toolbar"><label className="admin-search"><span>Search notifications</span><div><Icon name="search" /><input onChange={(event) => setSearch(event.target.value)} placeholder="Search title or message…" value={search} /></div></label><button className="admin-quiet-button" onClick={() => void load()} type="button"><Icon name="refresh" /> Refresh</button></div>
      {actionMessage && <p className={`admin-action-message ${/error|failed|denied/i.test(actionMessage) ? "is-error" : ""}`} role="status">{actionMessage}</p>}
      <section className="admin-card admin-notification-inbox"><div className="admin-card-heading"><div><h2>Notification inbox</h2><p>{rows.filter((row) => !first(row, ["is_read", "read_at"])).length} unread record{rows.filter((row) => !first(row, ["is_read", "read_at"])).length === 1 ? "" : "s"}</p></div><button className="admin-quiet-button" disabled={busyId !== "" || !rows.some((row) => !first(row, ["is_read", "read_at"]))} onClick={() => void markRead(rows.filter((row) => !first(row, ["is_read", "read_at"])).map((row) => String(row.id)))} type="button">{busyId === "all" ? "Marking…" : "Mark all as read"}</button></div>{visible.length ? <div>{visible.map((row, index) => { const unread = !first(row, ["is_read", "read_at"]); const type = String(first(row, ["type", "entity_type"]) ?? "Update"); const entityType = String(first(row, ["entity_type"]) ?? ""); const targetable = Boolean(first(row, ["entity_id"])) && /reservation|booking|payment|order|customer|profile/i.test(entityType); return <article className={unread ? "is-unread" : ""} key={String(row.id ?? index)}><i><Icon name={entityType === "reservation" ? "calendar" : type.toLowerCase().includes("payment") ? "card" : "bell"} /></i><span><small>{type.replace(/_/g, " ")}</small><strong>{show(first(row, ["title", "subject"]))}</strong><p>{show(first(row, ["message", "body", "content"]))}</p><time>{show(first(row, ["created_at"]), "created_at")}</time></span>{targetable && <button onClick={() => openLinkedRecord(row)} type="button">Open record</button>}{unread && <button disabled={busyId !== ""} onClick={() => void markRead([String(row.id)])} type="button">{busyId === String(row.id) ? "Saving…" : "Mark read"}</button>}</article>; })}</div> : <div className="admin-empty"><strong>No notifications found</strong><p>Operational notifications allowed by the current RLS policy will appear here.</p></div>}</section>
    </>
  );
}

function ActivityLogView() {
  const [rows, setRows] = useState<Row[]>([]);
  const [state, setState] = useState<LoadState>("loading");
  const [error, setError] = useState("");
  const [search, setSearch] = useState("");
  const load = useCallback(async () => {
    setState("loading"); setError("");
    const { data, error: queryError } = await supabase.from("admin_activity_logs").select("*").order("created_at", { ascending: false }).limit(500);
    if (queryError) { setError(queryError.message); setState("error"); return; }
    setRows((data ?? []) as Row[]); setState("ready");
  }, []);
  useEffect(() => { void load(); }, [load]);
  if (state === "loading") return <LoadingState />;
  if (state === "error") return <ErrorState message={error} retry={load} />;
  const visible = rows.filter((row) => !search.trim() || JSON.stringify(row).toLowerCase().includes(search.trim().toLowerCase()));
  return (
    <>
      <div className="admin-toolbar"><label className="admin-search"><span>Search activity</span><div><Icon name="search" /><input onChange={(event) => setSearch(event.target.value)} placeholder="Action, actor, or record…" value={search} /></div></label><button className="admin-quiet-button" onClick={() => void load()} type="button"><Icon name="refresh" /> Refresh</button></div>
      <section className="admin-card admin-activity-feed"><div className="admin-card-heading"><div><h2>Administrative timeline</h2><p>{visible.length} recorded event{visible.length === 1 ? "" : "s"}</p></div></div>{visible.length ? <div>{visible.map((row, index) => <article key={String(row.id ?? index)}><i><Icon name={String(first(row, ["action"]) ?? "").includes("payment") ? "card" : String(first(row, ["action"]) ?? "").includes("schedule") ? "calendar" : "clock"} /></i><span><strong>{show(first(row, ["action"]))}</strong><p>{show(first(row, ["description", "details"]))}</p><small>Actor: {show(first(row, ["admin_name", "admin_id", "user_id"]))} · {show(first(row, ["entity_type"]))} {show(first(row, ["entity_id"]))}</small><time>{show(first(row, ["created_at", "timestamp"]), "created_at")}</time></span></article>)}</div> : <div className="admin-empty"><strong>No activity recorded</strong><p>Secure admin actions will appear when the backend writes audit events.</p></div>}</section>
    </>
  );
}

type PaymentAccountMethod = "gcash" | "maya" | "bank_transfer" | "other" | "cash";
type PaymentAccount = {
  id: string;
  method: PaymentAccountMethod;
  display_name: string;
  account_holder: string;
  bank_name: string;
  account_number: string;
  mobile_wallet_number: string;
  instructions: string;
  qr_code_url: string;
  is_active: boolean;
  updated_at: string;
  updated_by: string;
};
type LegacyPaymentInstructions = {
  gcash_instructions: string;
  bank_transfer_instructions: string;
  cash_instructions: string;
};
type PendingPaymentSettingsChange =
  | { kind: "accounts"; accounts: PaymentAccount[] }
  | { kind: "legacy"; instructions: LegacyPaymentInstructions }
  | { kind: "demo_mode"; enabled: boolean };

const paymentMethodLabels: Record<PaymentAccountMethod, string> = {
  gcash: "GCash",
  maya: "Maya",
  bank_transfer: "Bank Transfer",
  other: "Other configured method",
  cash: "Cash",
};

function PaymentsWorkspace({ go }: { go: (path: string) => void }) {
  const [tab, setTab] = useState<"history" | "pending" | "accounts">("history");
  return <>
    <div aria-label="Payments sections" className="admin-payment-tabs" role="tablist">
      <button aria-selected={tab === "history"} className={tab === "history" ? "is-active" : ""} onClick={() => setTab("history")} role="tab" type="button">Payment History</button>
      <button aria-selected={tab === "pending"} className={tab === "pending" ? "is-active" : ""} onClick={() => setTab("pending")} role="tab" type="button">Pending Verification</button>
      <button aria-selected={tab === "accounts"} className={tab === "accounts" ? "is-active" : ""} onClick={() => setTab("accounts")} role="tab" type="button">Payment Account Settings</button>
    </div>
    {tab === "history" ? <DataTable defaultFilter="All" go={go} key="payment-history" section="payments" /> : tab === "pending" ? <DataTable defaultFilter="Pending" go={go} key="pending-verification" section="payments" /> : <PaymentAccountSettings />}
  </>;
}

function PaymentAccountSettings() {
  const [accounts, setAccounts] = useState<PaymentAccount[]>([]);
  const [legacyInstructions, setLegacyInstructions] = useState<LegacyPaymentInstructions>({ gcash_instructions: "", bank_transfer_instructions: "", cash_instructions: "" });
  const [updatedAt, setUpdatedAt] = useState<string | null>(null);
  const [demoMode, setDemoMode] = useState(true);
  const [audit, setAudit] = useState<Row[]>([]);
  const [people, setPeople] = useState<Record<string, string>>({});
  const [state, setState] = useState<LoadState>("loading");
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const [saving, setSaving] = useState(false);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState<PaymentAccount | null>(null);
  const [revealed, setRevealed] = useState<Record<string, boolean>>({});
  const [pendingChange, setPendingChange] = useState<PendingPaymentSettingsChange | null>(null);
  const [mfaPrompt, setMfaPrompt] = useState<{ factorId: string; challengeId: string; qrCode?: string } | null>(null);
  const [mfaCode, setMfaCode] = useState("");

  const load = useCallback(async () => {
    setState("loading");
    setError("");
    const [settings, auditResult, customerOptions] = await Promise.all([
      supabase.rpc("evently_admin_get_payment_accounts"),
      supabase.from("evently_payment_account_audit").select("id,changed_by,created_at,changed_methods").order("created_at", { ascending: false }).limit(20),
      supabase.rpc("evently_customer_payment_options"),
    ]);
    const failure = settings.error ?? auditResult.error;
    if (failure) { setError(failure.message); setState("error"); return; }
    const row = settings.data && !Array.isArray(settings.data) && typeof settings.data === "object"
      ? settings.data as Row & { accounts?: unknown; demo_mode?: boolean; legacy_instructions?: Partial<LegacyPaymentInstructions>; updated_at?: string | null }
      : null;
    const optionSettings = customerOptions.data && typeof customerOptions.data === "object"
      ? customerOptions.data as Row & { demo_mode?: boolean; legacy_instructions?: Partial<LegacyPaymentInstructions> }
      : null;
    const destinationRows = Array.isArray(settings.data) ? settings.data as Row[] : [];
    const nextAccounts = Array.isArray(row?.accounts)
      ? row.accounts as PaymentAccount[]
      : destinationRows.map((destination): PaymentAccount => {
        const method = String(destination.method ?? "gcash") as PaymentAccountMethod;
        return {
          id: String(destination.id ?? ""),
          method,
          display_name: String(destination.display_name ?? ""),
          account_holder: String(destination.account_name ?? ""),
          bank_name: String(destination.bank_name ?? ""),
          account_number: String(destination.account_number ?? ""),
          mobile_wallet_number: method === "gcash" || method === "maya" ? String(destination.account_number ?? "") : "",
          instructions: String(destination.instructions ?? ""),
          qr_code_url: String(destination.qr_image_url ?? ""),
          is_active: destination.is_enabled === true,
          updated_at: String(destination.updated_at ?? ""),
          updated_by: "",
        };
      });
    const nextAudit = (auditResult.data ?? []) as Row[];
    const actorIds = Array.from(new Set([
      ...nextAccounts.map((account) => account.updated_by).filter(Boolean),
      ...nextAudit.map((item) => String(item.changed_by ?? "")).filter(Boolean),
    ]));
    if (actorIds.length) {
      const profiles = await supabase.from("profiles").select("id,full_name").in("id", actorIds);
      if (!profiles.error) setPeople(Object.fromEntries((profiles.data ?? []).map((profile) => [profile.id, profile.full_name || profile.id])));
    }
    setAccounts(nextAccounts);
    setLegacyInstructions({
      gcash_instructions: String(row?.legacy_instructions?.gcash_instructions ?? optionSettings?.legacy_instructions?.gcash_instructions ?? ""),
      bank_transfer_instructions: String(row?.legacy_instructions?.bank_transfer_instructions ?? optionSettings?.legacy_instructions?.bank_transfer_instructions ?? ""),
      cash_instructions: String(row?.legacy_instructions?.cash_instructions ?? optionSettings?.legacy_instructions?.cash_instructions ?? ""),
    });
    setUpdatedAt(row?.updated_at ?? null);
    setDemoMode((row?.demo_mode ?? optionSettings?.demo_mode) !== false);
    setAudit(nextAudit);
    setState("ready");
  }, []);

  useEffect(() => {
    void load();
    const channel = supabase.channel("admin-payment-settings")
      .on("postgres_changes", { event: "*", schema: "public", table: "evently_business_settings" }, () => { void load(); })
      .subscribe();
    return () => { void supabase.removeChannel(channel); };
  }, [load]);

  const publishAccounts = async (nextAccounts: PaymentAccount[]) => {
    setSaving(true);
    setMessage("");
    const { error: publishError } = await supabase.rpc("evently_admin_save_payment_accounts", {
      p_accounts: nextAccounts.map(({ id, method, display_name, account_holder, bank_name, account_number, mobile_wallet_number, instructions, qr_code_url, is_active }) => ({
        id, method, display_name, account_holder, bank_name, account_number, mobile_wallet_number, instructions, qr_code_url, is_active,
      })),
      p_expected_updated_at: updatedAt,
    });
    setSaving(false);
    if (publishError) { setMessage(publishError.message); return; }
    setMessage("Payment destination changes were securely published and audited.");
    setPendingChange(null);
    await load();
  };

  const publishLegacyInstructions = async (instructions: LegacyPaymentInstructions) => {
    setSaving(true);
    setMessage("");
    const { error: publishError } = await supabase.rpc("evently_admin_save_legacy_payment_instructions", {
      p_instructions: instructions,
      p_expected_updated_at: updatedAt,
    });
    setSaving(false);
    if (publishError) { setMessage(publishError.message); return; }
    setMessage("Legacy customer payment instructions were securely saved and audited.");
    setPendingChange(null);
    await load();
  };

  const publishDemoMode = async (enabled: boolean) => {
    setSaving(true);
    setMessage("");
    const { error: publishError } = await supabase.rpc("evently_admin_set_demo_payment_mode", {
      p_enabled: enabled,
      p_expected_updated_at: updatedAt,
    });
    setSaving(false);
    if (publishError) { setMessage(publishError.message); return; }
    setMessage(`Demo payment mode ${enabled ? "enabled" : "disabled"}. Existing payment records retain their original mode.`);
    setPendingChange(null);
    await load();
  };

  const requestSecurePublish = async (change: PendingPaymentSettingsChange) => {
    const { data: factors, error: factorError } = await supabase.auth.mfa.listFactors();
    if (factorError) { setMessage(factorError.message); return; }
    let factorId = factors.totp.find((factor) => factor.status === "verified")?.id ?? "";
    let qrCode: string | undefined;
    if (!factorId) {
      const { data: enrollment, error: enrollmentError } = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: "EVENTLY payment destination changes" });
      if (enrollmentError) { setMessage(enrollmentError.message); return; }
      factorId = enrollment.id;
      qrCode = enrollment.totp.qr_code;
    }
    const { data: challenge, error: challengeError } = await supabase.auth.mfa.challenge({ factorId });
    if (challengeError) { setMessage(challengeError.message); return; }
    setPendingChange(change);
    setMfaPrompt({ factorId, challengeId: challenge.id, qrCode });
    setMfaCode("");
  };

  const verifyAndPublish = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!mfaPrompt || !pendingChange || saving) return;
    setSaving(true);
    const { error: verifyError } = await supabase.auth.mfa.verify({
      factorId: mfaPrompt.factorId,
      challengeId: mfaPrompt.challengeId,
      code: mfaCode.trim(),
    });
    setSaving(false);
    if (verifyError) { setMessage(verifyError.message); return; }
    setMfaPrompt(null);
    if (pendingChange.kind === "accounts") await publishAccounts(pendingChange.accounts);
    else if (pendingChange.kind === "legacy") await publishLegacyInstructions(pendingChange.instructions);
    else await publishDemoMode(pendingChange.enabled);
  };

  const openNew = () => {
    setMessage("");
    setDraft({ id: crypto.randomUUID(), method: "gcash", display_name: "GCash", account_holder: "", bank_name: "", account_number: "", mobile_wallet_number: "", instructions: "", qr_code_url: "", is_active: true, updated_at: "", updated_by: "" });
    setEditing(true);
  };
  const openEdit = (account: PaymentAccount) => { setMessage(""); setDraft({ ...account }); setEditing(true); };
  const saveDraft = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!draft || saving) return;
    if (!draft.display_name.trim() || !draft.instructions.trim()) { setMessage("Enter a display name and customer instructions."); return; }
    if (draft.method === "bank_transfer" && (!draft.bank_name.trim() || !draft.account_number.trim() || !draft.account_holder.trim())) { setMessage("Bank name, account number, and account holder are required."); return; }
    if (["gcash", "maya"].includes(draft.method) && (!draft.mobile_wallet_number.trim() || !draft.account_holder.trim())) { setMessage("Wallet number and account holder are required."); return; }
    if (draft.method === "other" && !draft.account_number.trim() && !draft.mobile_wallet_number.trim()) { setMessage("Enter an account or wallet destination for this method."); return; }
    if (draft.method === "cash" && !draft.instructions.trim()) { setMessage("Enter cash payment instructions."); return; }
    if (draft.is_active && accounts.some((account) => account.id !== draft.id && account.method === draft.method && account.is_active)) {
      setMessage(`Deactivate the existing ${paymentMethodLabels[draft.method]} destination before publishing another.`);
      return;
    }
    const next = accounts.some((account) => account.id === draft.id)
      ? accounts.map((account) => account.id === draft.id ? draft : account)
      : [...accounts, draft];
    if (!window.confirm("Publish these customer-facing payment destination details? This does not change any payment processor or bank payout account.")) return;
    setEditing(false);
    const change: PendingPaymentSettingsChange = { kind: "accounts", accounts: next };
    setPendingChange(change);
    await requestSecurePublish(change);
  };
  const saveLegacyInstructions = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (saving) return;
    if (Object.values(legacyInstructions).some((value) => value.length > 1500)) {
      setMessage("Each legacy instruction must be 1,500 characters or fewer.");
      return;
    }
    if (!window.confirm("Save the legacy payment instructions? A fresh authenticator code is required. These are used only when no payment account destinations have been published.")) return;
    const change: PendingPaymentSettingsChange = { kind: "legacy", instructions: legacyInstructions };
    setPendingChange(change);
    await requestSecurePublish(change);
  };
  const toggleAccount = async (account: PaymentAccount) => {
    const nextActive = !account.is_active;
    if (nextActive && accounts.some((item) => item.id !== account.id && item.method === account.method && item.is_active)) {
      setMessage(`Deactivate the existing ${paymentMethodLabels[account.method]} destination before publishing this one.`);
      return;
    }
    if (!window.confirm(`${nextActive ? "Publish" : "Deactivate"} ${account.display_name} for customer payments?`)) return;
    await requestSecurePublish({ kind: "accounts", accounts: accounts.map((item) => item.id === account.id ? { ...item, is_active: nextActive } : item) });
  };
  const toggleDemoMode = async () => {
    const enabled = !demoMode;
    if (!window.confirm(`${enabled ? "Enable" : "Disable"} Demo Payment mode? New submissions will ${enabled ? "be labeled as demonstration records and not actual money transfers" : "be recorded as manual payment proof without the demo label"}.`)) return;
    await requestSecurePublish({ kind: "demo_mode", enabled });
  };

  if (state === "loading") return <LoadingState />;
  if (state === "error") return <ErrorState message={`${error}. Apply the EVENTLY payment-account migration before managing destinations.`} retry={load} />;
  return <>
    <div className="admin-payment-settings-intro"><div><span>Customer-visible destinations</span><h2>Payment Account Settings</h2><p>Publish the instructions and account details customers should use. This only changes displayed instructions; it does not redirect processor payouts. Keep at most one active destination per payment method.</p></div><div className="admin-payment-settings-intro__actions"><button className="admin-quiet-button" disabled={saving || Boolean(mfaPrompt)} onClick={() => void load()} type="button"><Icon name="refresh" /> Refresh</button><button className="admin-secondary-button" disabled={saving || Boolean(mfaPrompt)} onClick={openNew} type="button">Add payment method</button></div></div>
    {message && <p className={`admin-action-message ${/failed|error|invalid|requires|must/i.test(message) ? "is-error" : ""}`} role="status">{message}</p>}
    <section className="admin-card admin-demo-payment-setting"><div><span>Manual / capstone workflow</span><h2>{demoMode ? "Demo payment mode is ON" : "Demo payment mode is OFF"}</h2><p>{demoMode ? "Customers see “Demo Payment — No Actual Money Transfer”. Submitted sample receipts can be accepted for booking review but are not financial settlement." : "Customers see standard manual payment instructions. Uploaded references and receipts still require administrator verification."}</p></div><button className="admin-secondary-button" disabled={saving || Boolean(mfaPrompt)} onClick={() => void toggleDemoMode()} type="button">{demoMode ? "Disable Demo Mode" : "Enable Demo Mode"}</button></section>
    <section className="admin-card admin-legacy-payment-instructions"><div className="admin-card-heading"><div><h2>Legacy payment instructions</h2><p>Retained for existing checkout compatibility. These are shown only when no payment-account destinations have been configured.</p></div></div><form onSubmit={(event) => void saveLegacyInstructions(event)}>{(["gcash_instructions", "bank_transfer_instructions", "cash_instructions"] as const).map((key) => <label key={key}>{key.replace("_instructions", "").replace("_", " ")}<textarea maxLength={1500} onChange={(event) => setLegacyInstructions((current) => ({ ...current, [key]: event.target.value }))} rows={3} value={legacyInstructions[key]} /></label>)}<button className="admin-secondary-button" disabled={saving || Boolean(mfaPrompt)} type="submit">{saving ? "Verifying…" : "Save Legacy Instructions"}</button></form></section>
    {!accounts.length ? <section className="admin-card admin-empty"><strong>No payment destinations configured</strong><p>Add a method to publish customer payment instructions. Existing legacy instructions remain available until the first destination is published.</p></section> : <div className="admin-payment-account-grid">{accounts.map((account) => {
      const destination = account.method === "bank_transfer" ? account.account_number : account.mobile_wallet_number || account.account_number;
      const masked = destination ? `${"•".repeat(Math.max(0, destination.length - 4))}${destination.slice(-4)}` : "Not provided";
      return <article className="admin-card admin-payment-account" key={account.id}>
        <div className="admin-payment-account__header"><span className="admin-payment-account__mark">{paymentMethodLabels[account.method]?.slice(0, 1) ?? "P"}</span><div><span>{paymentMethodLabels[account.method] ?? "Other method"}</span><h3>{account.display_name}</h3></div><Value label="status" value={account.is_active ? "Active" : "Inactive"} /></div>
        <dl><div><dt>Account holder</dt><dd>{account.account_holder || "—"}</dd></div>{account.bank_name && <div><dt>Bank</dt><dd>{account.bank_name}</dd></div>}{account.method !== "cash" && <div><dt>{account.method === "bank_transfer" ? "Account number" : "Destination number"}</dt><dd>{revealed[account.id] ? destination || "—" : masked}<button aria-label={`${revealed[account.id] ? "Hide" : "Reveal"} ${account.display_name} destination`} className="admin-reveal-button" onClick={() => setRevealed((current) => ({ ...current, [account.id]: !current[account.id] }))} type="button">{revealed[account.id] ? "Hide" : "Reveal"}</button></dd></div>}<div><dt>Customer instructions</dt><dd>{account.instructions || "—"}</dd></div></dl>
        {account.qr_code_url && <img alt={`${account.display_name} payment QR code`} className="admin-payment-qr" src={account.qr_code_url} />}
        <p className="admin-payment-account__audit">Updated {show(account.updated_at, "updated_at")} · {people[account.updated_by] ?? "Administrator"}</p>
        <div className="admin-payment-account__actions"><button className="admin-quiet-button" disabled={saving || Boolean(mfaPrompt)} onClick={() => void toggleAccount(account)} type="button">{account.is_active ? "Deactivate" : "Publish"}</button><button className="admin-secondary-button" disabled={saving || Boolean(mfaPrompt)} onClick={() => openEdit(account)} type="button">Edit Details</button></div>
      </article>;
    })}</div>}
    <section className="admin-card admin-payment-audit"><div className="admin-card-heading"><div><h2>Payment settings audit</h2><p>Private audit records retain previous and published details for authorized administrators.</p></div></div>{audit.length ? <ul>{audit.map((item) => { const methods = Array.isArray(item.changed_methods) ? item.changed_methods as string[] : []; return <li key={String(item.id)}><span><strong>{methods.includes("legacy_instructions") ? "Legacy payment instructions updated" : methods.includes("demo_payment_mode") ? "Demo payment mode changed" : "Payment destinations changed"}</strong><small>{methods.filter((method) => method !== "legacy_instructions").join(", ") || "Legacy instructions"} · {people[String(item.changed_by)] ?? "Administrator"}</small></span><time>{show(item.created_at, "created_at")}</time></li>; })}</ul> : <p>No payment settings changes recorded.</p>}</section>
    {editing && draft && <div className="admin-modal-wrap"><button aria-label="Close payment editor" className="admin-modal-backdrop" onClick={() => setEditing(false)} type="button" /><section aria-labelledby="payment-account-editor-title" aria-modal="true" className="admin-editor-modal" role="dialog"><div className="admin-editor-modal__heading"><div><span>Secure payment settings</span><h2 id="payment-account-editor-title">{accounts.some((item) => item.id === draft.id) ? "Edit Details" : "Add payment method"}</h2></div><button aria-label="Close payment editor" onClick={() => setEditing(false)} type="button">×</button></div><form onSubmit={(event) => void saveDraft(event)}>
      <label>Payment method<select onChange={(event) => { const method = event.target.value as PaymentAccountMethod; setDraft((current) => current ? { ...current, method, display_name: current.display_name === paymentMethodLabels[current.method] ? paymentMethodLabels[method] : current.display_name } : current); }} value={draft.method}>{Object.entries(paymentMethodLabels).map(([method, label]) => <option key={method} value={method}>{label}</option>)}</select></label>
      <label>Display name<input onChange={(event) => setDraft({ ...draft, display_name: event.target.value })} required value={draft.display_name} /></label>
      <label>Account holder name<input onChange={(event) => setDraft({ ...draft, account_holder: event.target.value })} value={draft.account_holder} /></label>
      {draft.method === "bank_transfer" && <label>Bank name<input onChange={(event) => setDraft({ ...draft, bank_name: event.target.value })} required value={draft.bank_name} /></label>}
      {draft.method === "bank_transfer" || draft.method === "other" ? <label>Account number<input autoComplete="off" onChange={(event) => setDraft({ ...draft, account_number: event.target.value })} value={draft.account_number} /></label> : null}
      {["gcash", "maya", "other"].includes(draft.method) && <label>Mobile wallet number<input autoComplete="off" onChange={(event) => setDraft({ ...draft, mobile_wallet_number: event.target.value })} value={draft.mobile_wallet_number} /></label>}
      <label>Customer payment instructions<textarea onChange={(event) => setDraft({ ...draft, instructions: event.target.value })} required rows={4} value={draft.instructions} /></label>
      <label>QR code image URL (optional)<input onChange={(event) => setDraft({ ...draft, qr_code_url: event.target.value })} placeholder="https://…" type="url" value={draft.qr_code_url} /></label>
      <label className="admin-editor-checkbox"><input checked={draft.is_active} onChange={(event) => setDraft({ ...draft, is_active: event.target.checked })} type="checkbox" /> Publish as active</label>
      <p className="admin-security-note">Never enter banking passwords, PINs, OTPs, or payment-provider credentials. Publishing requires a verified MFA code.</p>
      {message && !mfaPrompt && <p className="admin-action-message is-error" role="alert">{message}</p>}
      <div className="admin-editor-modal__actions"><button className="admin-quiet-button" onClick={() => setEditing(false)} type="button">Cancel</button><button className="admin-secondary-button" disabled={saving} type="submit">{saving ? "Verifying…" : "Publish Changes"}</button></div>
    </form></section></div>}
    {mfaPrompt && <div className="admin-modal-wrap"><button aria-label="Cancel MFA verification" className="admin-modal-backdrop" onClick={() => { setMfaPrompt(null); setPendingChange(null); }} type="button" /><section aria-labelledby="payment-mfa-title" aria-modal="true" className="admin-editor-modal admin-mfa-modal" role="dialog"><div className="admin-editor-modal__heading"><div><span>Additional verification</span><h2 id="payment-mfa-title">Verify before publishing</h2></div><button aria-label="Cancel MFA verification" onClick={() => { setMfaPrompt(null); setPendingChange(null); }} type="button">×</button></div><p>Enter a fresh code from your authenticator app. Every payment destination or instruction change requires a new MFA challenge.</p>{mfaPrompt.qrCode && <div className="admin-mfa-setup"><img alt="Scan this QR code with an authenticator app" src={mfaPrompt.qrCode} /><span>Scan the code, then enter the generated 6-digit code below.</span></div>}<form onSubmit={(event) => void verifyAndPublish(event)}><label>Authenticator code<input autoComplete="one-time-code" inputMode="numeric" maxLength={8} onChange={(event) => setMfaCode(event.target.value)} required value={mfaCode} /></label>{message && <p className="admin-action-message is-error" role="alert">{message}</p>}<div className="admin-editor-modal__actions"><button className="admin-quiet-button" onClick={() => { setMfaPrompt(null); setPendingChange(null); }} type="button">Cancel</button><button className="admin-secondary-button" disabled={saving} type="submit">{saving ? "Verifying…" : "Verify and Publish"}</button></div></form></section></div>}
  </>;
}

function FeaturedPhotosSettings() {
  const [selected, setSelected] = useState<Record<string, number>>({ catering: 3, events: 4, resort: 3 });
  const [message, setMessage] = useState("");
  const [saving, setSaving] = useState("");
  const categories = [{ id: "catering", label: "Catering", folder: "CATERING", prefix: "catering_sample", count: 10 }, { id: "events", label: "Events", folder: "EVENTS PLACE", prefix: "eventsplace_sample", count: 15 }, { id: "resort", label: "Resort / Staycation", folder: "STAYCATION-RESORT", prefix: "resort_sample", count: 9 }];
  useEffect(() => {
    supabase.from("evently_featured_photos").select("category,photo_index").then(({ data, error }) => {
      if (error) setMessage(error.message);
      else if (data) setSelected((previous) => ({ ...previous, ...Object.fromEntries(data.map((item) => [item.category, Number(item.photo_index)])) }));
    });
  }, []);
  const save = async (category: string) => {
    setSaving(category);
    setMessage("");
    const { data: user } = await supabase.auth.getUser();
    const { error } = await supabase.from("evently_featured_photos").upsert({ category, photo_index: selected[category], updated_by: user.user?.id ?? null, updated_at: new Date().toISOString() }, { onConflict: "category" });
    setMessage(error ? error.message : "Featured " + category + " photo saved. Refresh the customer gallery to see the change.");
    setSaving("");
  };
  return <section className="admin-card"><span>Homepage gallery</span><h2>Featured story photos</h2><p>Choose the starting photo for each gallery story. Visitors can browse the other photos with the arrows. Images are selected from the existing Venice photo collection.</p><div className="featured-admin-grid">{categories.map((category) => <div key={category.id}><h3>{category.label}</h3><img alt={category.label + " preview"} style={{ width: "100%", aspectRatio: "4 / 3", objectFit: "cover", borderRadius: 12 }} src={"/venice-photos/" + encodeURIComponent(category.folder) + "/" + category.prefix + (selected[category.id] + 1) + ".jpg"} /><label>Featured photo<select value={selected[category.id]} onChange={(event) => setSelected((previous) => ({ ...previous, [category.id]: Number(event.target.value) }))}>{Array.from({ length: category.count }, (_, index) => <option key={index} value={index}>Photo {index + 1}</option>)}</select></label><button type="button" disabled={saving === category.id} onClick={() => save(category.id)}>{saving === category.id ? "Saving…" : "Save featured photo"}</button></div>)}</div>{message && <p role="status">{message}</p>}</section>;
}

function Settings() {
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState("");
  const update = async () => {
    setMessage("Updating…");
    const { error } = await supabase.auth.updateUser({ password });
    setMessage(error ? error.message : "Password updated successfully.");
    if (!error) setPassword("");
  };
  return <div className="admin-settings-grid"><FeaturedPhotosSettings /><section className="admin-card admin-password-card"><span>Account security</span><h2>Change password</h2><p>Update the password for the currently authenticated Supabase account.</p><label>New password<input minLength={8} onChange={(event) => setPassword(event.target.value)} type="password" value={password} /></label><button disabled={password.length < 8} onClick={update} type="button">Update password</button>{message && <p role="status">{message}</p>}</section></div>;
}

const staffPermissions = [
  ["view_reservations", "View reservations"], ["edit_reservation_details", "Edit permitted details"],
  ["propose_schedule_changes", "Propose schedule changes"], ["view_calendar", "View calendar"],
  ["view_customer_details", "View customer details"], ["recommend_approval", "Recommend approval"],
  ["recommend_rejection", "Recommend rejection"], ["moderate_reviews", "Moderate reviews"],
  ["view_orders", "View operational orders"],
] as const;

function StaffManagement({ isOwner }: { isOwner: boolean }) {
  const [staff, setStaff] = useState<Row[]>([]);
  const [grants, setGrants] = useState<Row[]>([]);
  const [activity, setActivity] = useState<Row[]>([]);
  const [policies, setPolicies] = useState<Row[]>([]);
  const [selectedId, setSelectedId] = useState("");
  const [search, setSearch] = useState("");
  const [email, setEmail] = useState("");
  const [fullName, setFullName] = useState("");
  const [staffUsername, setStaffUsername] = useState("");
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState("");
  const [loading, setLoading] = useState(true);
  const load = useCallback(async () => {
    const [people, permissions, recommendations, policy] = await Promise.all([
      supabase.from("profiles").select("id,email,full_name,created_at,role,staff_active").eq("role","staff").order("created_at",{ascending:false}),
      supabase.from("evently_staff_permissions").select("staff_id,permission,granted,updated_at"),
      supabase.from("evently_booking_recommendations").select("staff_id,recommendation,review_state,created_at"),
      supabase.from("evently_staff_permission_policy").select("permission,allowed_for_admins,updated_at"),
    ]);
    const error = people.error ?? permissions.error ?? recommendations.error ?? policy.error;
    if (error) setMessage("Staff records could not be loaded: " + error.message);
    else {
      setStaff((people.data ?? []) as Row[]);
      setGrants((permissions.data ?? []) as Row[]);
      setActivity((recommendations.data ?? []) as Row[]);
      setPolicies((policy.data ?? []) as Row[]);
    }
    setLoading(false);
  }, []);
  useEffect(() => { void load(); }, [load]);
  const allowed = (key: string) => policies.some(p => p.permission === key && p.allowed_for_admins === true);
  const assigned = (id: unknown, key: string) => grants.some(g => g.staff_id === id && g.permission === key && g.granted === true);
  const effectiveCount = (person: Row) => staffPermissions.filter(([key]) => allowed(key) && assigned(person.id,key)).length;
  const visible = staff.filter(person => (String(person.full_name ?? "") + " " + String(person.email ?? "")).toLowerCase().includes(search.toLowerCase()));
  const chosen = visible.find(person => String(person.id) === selectedId) ?? visible[0] ?? null;
  const allowedCount = staffPermissions.filter(([key]) => allowed(key)).length;
  const groups = [
    { title:"Booking operations", description:"Bookings, schedules, and operational orders", keys:["view_reservations","view_calendar","view_orders","edit_reservation_details","propose_schedule_changes"] },
    { title:"Customer & reviews", description:"Sensitive customer records and feedback", keys:["view_customer_details","moderate_reviews"] },
    { title:"Recommendations", description:"Submit recommendations for Admin final review", keys:["recommend_approval","recommend_rejection"] }
  ];
  const setGrant = async (id:string,key:string,granted:boolean) => {
    setBusy("grant:"+key); setMessage("");
    try {
      const {error} = await supabase.rpc("evently_manage_staff_permission",{p_staff_id:id,p_permission:key,p_granted:granted});
      setMessage(error ? error.message : "Staff permission saved.");
      if (!error) await load();
    } finally { setBusy(""); }
  };
  const setPolicy = async (key:string,enabled:boolean) => {
    setBusy("policy:"+key); setMessage("");
    try {
      const {error} = await supabase.rpc("evently_owner_set_staff_permission_policy",{p_permission:key,p_allowed:enabled});
      setMessage(error ? error.message : "Owner permission policy saved.");
      if (!error) await load();
    } finally { setBusy(""); }
  };
  const setActive = async (id:string,active:boolean) => {
    setBusy("status"); setMessage("");
    try {
      const {error} = await supabase.rpc("evently_admin_set_staff_active",{p_staff_id:id,p_active:active});
      setMessage(error ? error.message : active ? "Staff account activated." : "Staff account deactivated.");
      if (!error) await load();
    } finally { setBusy(""); }
  };
  const editStaff = async (person:Row) => {
    const name = window.prompt("Staff member name",String(person.full_name ?? ""))?.trim();
    if (!name) return;
    setBusy("profile"); setMessage("");
    try {
      const {error} = await supabase.from("profiles").update({full_name:name}).eq("id",person.id);
      setMessage(error ? error.message : "Staff profile updated.");
      if (!error) await load();
    } finally { setBusy(""); }
  };
  const invite = async (event:React.FormEvent<HTMLFormElement>) => {
    event.preventDefault(); setBusy("invite"); setMessage("");
    try {
      const normalizedUsername = staffUsername.trim().toLowerCase();
      if (!/^[a-z][a-z0-9._-]{2,29}$/.test(normalizedUsername)) {
        setMessage("Username must be 3–30 characters, start with a letter, and contain only lowercase letters, numbers, dots, underscores, or hyphens.");
        return;
      }
      const {error} = await supabase.functions.invoke("evently-staff-invite",{body:{email:email.trim(),full_name:fullName.trim(),username:normalizedUsername}});
      if (error) {
        let detail = error.message;
        if ("context" in error && error.context instanceof Response) {
          const data = await error.context.json().catch(() => null);
          detail = data?.error ?? detail;
        }
        setMessage("Invitation failed: " + detail);
      } else {
        setMessage("Invitation sent to " + email.trim() + ".");
        setEmail(""); setFullName(""); setStaffUsername(""); await load();
      }
    } catch (err) { setMessage(err instanceof Error ? err.message : "Could not invite staff."); }
    finally { setBusy(""); }
  };
  return <main className="team-page">
    <header className="team-header">
      <div><span className="team-kicker">TEAM ADMINISTRATION</span><h2>Staff Management</h2><p>Manage staff accounts and access without leaving the dashboard.</p></div>
      <div className="team-header-actions">
        <button className="admin-secondary-button" type="button" onClick={() => void load()}>Refresh</button>
        <button className="team-primary" type="button" onClick={() => { const panel=document.getElementById("team-invite") as HTMLDetailsElement | null; if (panel) {panel.open=true;panel.scrollIntoView({behavior:"smooth",block:"center"});} }}>Invite staff</button>
      </div>
    </header>
    <div className="team-stats" aria-label="Staff overview">
      <div><span>Team members</span><strong>{staff.length}</strong><small>Registered staff</small></div>
      <div><span>Active accounts</span><strong>{staff.filter(p=>p.staff_active !== false).length}</strong><small>Enabled staff</small></div>
      <div><span>Available permissions</span><strong>{allowedCount} / {staffPermissions.length}</strong><small>Enabled by Owner</small></div>
    </div>
    {message && <div className="team-message" role="status"><span>{message}</span><button type="button" aria-label="Dismiss message" onClick={()=>setMessage("")}>×</button></div>}
    <section className="team-workspace admin-card" aria-label="Staff accounts and permissions">
      <div className="team-workspace-title"><div><span className="team-kicker">PEOPLE & ACCESS</span><h3>Team permissions</h3><p>Select someone to view or adjust their permissions.</p></div><span className="team-count">{staff.length} members</span></div>
      <div className="team-columns">
        <aside className="team-list" aria-label="Team members">
          <label>Search team members<input type="search" value={search} onChange={e=>setSearch(e.target.value)} placeholder="Name or email" /></label>
          <div className="team-list-items">{visible.map(person=><button className={"team-person"+(chosen?.id===person.id?" selected":"")} key={String(person.id)} type="button" aria-pressed={chosen?.id===person.id} onClick={()=>setSelectedId(String(person.id))}>
            <span className="team-avatar">{String(person.full_name || person.email || "S").charAt(0).toUpperCase()}</span>
            <span><strong>{show(person.full_name)}</strong><small>{show(person.email)}</small><small>{effectiveCount(person)} permissions · {person.staff_active === false ? "Inactive" : "Active"}</small></span>
          </button>)}{!visible.length && <p>No matching staff found.</p>}</div>
        </aside>
        <div className="team-details">
          {loading ? <p>Loading staff accounts…</p> : chosen ? <>
            <div className="team-person-heading"><div><span className="team-kicker">STAFF PROFILE</span><h3>{show(chosen.full_name)}</h3><p>{show(chosen.email)}</p></div><span className={"team-state"+(chosen.staff_active===false?" inactive":"")}>{chosen.staff_active===false?"Inactive":"Active"}</span></div>
            <div className="team-person-actions"><span>{effectiveCount(chosen)} of {allowedCount} available permissions assigned</span><button className="admin-secondary-button" disabled={Boolean(busy)} type="button" onClick={()=>void editStaff(chosen)}>Edit profile</button><button className="admin-secondary-button" disabled={Boolean(busy)} type="button" onClick={()=>void setActive(String(chosen.id),chosen.staff_active===false)}>{chosen.staff_active===false?"Activate":"Deactivate"}</button></div>
            <h4>Staff access</h4><p className="team-help">Only permissions enabled in Owner policy can be assigned. Changes save automatically.</p>
            {groups.map(group=><section className="team-permission-group" key={group.title}><h5>{group.title}</h5><p>{group.description}</p><div className="team-permissions">{staffPermissions.filter(([key])=>group.keys.includes(key)).map(([key,title])=>{
              const enabled=allowed(key),granted=assigned(chosen.id,key);
              return <label className={"team-permission"+(!enabled?" locked":"")} key={key}><span><strong>{title}</strong><small>{!enabled?"Disabled by Owner":granted?"Access granted":"Not assigned"}</small></span><input type="checkbox" checked={enabled&&granted} disabled={!enabled||Boolean(busy)} onChange={e=>void setGrant(String(chosen.id),key,e.target.checked)} aria-label={title+" for "+String(chosen.full_name??"staff")} /></label>;
            })}</div></section>)}
            <div className="team-activity"><strong>Recent activity</strong><p>{activity.filter(x=>x.staff_id===chosen.id).length} booking recommendations submitted</p></div>
          </> : <p className="team-help">Choose a staff member, or invite someone to get started.</p>}
        </div>
      </div>
    </section>
    <div className="team-extras">
      <details className="team-disclosure admin-card"><summary><span className="team-square">⚙</span><span><strong>Owner permission policy</strong><small>{allowedCount} of {staffPermissions.length} capabilities available · Owner only</small></span><span aria-hidden="true">⌄</span></summary>
        <div className="team-disclosure-body"><p>Set which capabilities can be granted to staff. Disabling one removes its effective access even if it was previously assigned.</p>
          {groups.map(group=><section className="team-policy-group" key={group.title}><h4>{group.title}</h4>{staffPermissions.filter(([key])=>group.keys.includes(key)).map(([key,title])=><label key={key} className="team-policy"><span>{title}</span><span>{allowed(key)?"Allowed":"Disabled"} <input type="checkbox" checked={allowed(key)} disabled={!isOwner||Boolean(busy)} aria-label={"Allow "+title} onChange={e=>void setPolicy(key,e.target.checked)} /></span></label>)}</section>)}
          {!isOwner && <p>Only the Owner can change permission policies.</p>}
        </div>
      </details>
      <details className="team-disclosure admin-card" id="team-invite"><summary><span className="team-square">+</span><span><strong>Invite a team member</strong><small>Send a secure invitation to a new staff account</small></span><span aria-hidden="true">⌄</span></summary>
        <div className="team-disclosure-body"><p>Assign a unique username and email. Staff members set their own password through a secure invitation email before receiving access.</p><form onSubmit={e=>void invite(e)} className="team-invite-form">
          <label>Full name<input required value={fullName} onChange={e=>setFullName(e.target.value)} placeholder="Full name" /></label>
          <label>Username<input required autoComplete="off" minLength={3} maxLength={30} pattern="[A-Za-z][A-Za-z0-9._-]{2,29}" value={staffUsername} onChange={e=>setStaffUsername(e.target.value)} placeholder="e.g. maria.santos" /></label>
          <label>Email address<input type="email" required value={email} onChange={e=>setEmail(e.target.value)} placeholder="name@example.com" /></label>
          <button className="team-primary" disabled={Boolean(busy)} type="submit">{busy==="invite"?"Sending invitation…":"Send invitation"}</button>
        </form></div>
      </details>
    </div>
  </main>;
}

function RecommendationsView() {
  const [rows, setRows] = useState<Row[]>([]);
  const [message, setMessage] = useState("");
  const load = useCallback(async () => {
    const { data: recommendations, error } = await supabase.from("evently_booking_recommendations").select("*").eq("review_state", "awaiting_admin").order("created_at", { ascending: true });
    if (error) { setMessage(error.message); return; }
    const [reservations, profiles, staffNotes, packages] = await Promise.all([supabase.from("reservations").select("*"), supabase.from("profiles").select("id,full_name"), supabase.from("evently_reservation_staff_notes").select("reservation_id,note,created_at,staff_id").order("created_at", { ascending: false }), supabase.from("packages").select("id,name")]);
    const bookings = (reservations.data ?? []) as Row[]; const people = (profiles.data ?? []) as Row[]; const notesByReservation = (staffNotes.data ?? []) as Row[];
    setRows(((recommendations ?? []) as Row[]).map((rec) => { const booking = bookings.find((item) => item.id === rec.reservation_id); return { ...rec, _booking: booking, _customer: people.find((person) => person.id === booking?.customer_id), _package: (packages.data ?? []).find((p) => p.id === booking?.package_id), _staff: people.find((person) => person.id === rec.staff_id), _staff_notes: notesByReservation.filter((note) => note.reservation_id === rec.reservation_id) }; }));
  }, []);
  useEffect(() => { void load(); const event = () => void load(); const interval = window.setInterval(() => void load(), 30000); window.addEventListener("evently-admin-data-changed", event); return () => { window.clearInterval(interval); window.removeEventListener("evently-admin-data-changed", event); }; }, [load]);
  const decide = async (row: Row, decision: "approve" | "reject" | "return") => {
    const booking = row._booking as Row | undefined;
    const reason = decision === "return" || decision === "reject" ? window.prompt(decision === "return" ? "What should staff revise?" : "Enter the final rejection reason:")?.trim() : null;
    if ((decision !== "approve") && !reason) return;
    if (decision === "approve" && !window.confirm("Confirm schedule details and submit the server-validated final approval?")) return;
    const { error } = await supabase.rpc("evently_admin_review_booking_recommendation", {
      p_recommendation_id: String(row.id), p_decision: decision, p_reason: reason,
      p_schedule_verified: decision === "approve",
    });
    setMessage(error ? error.message : `Recommendation ${decision === "return" ? "returned for revision" : `finalized: ${decision}`}.`);
    if (!error) { await load(); window.dispatchEvent(new Event("evently-admin-data-changed")); window.dispatchEvent(new Event("evently-customer-bookings-changed")); }
    void booking;
  };
  return <section className="admin-card admin-table-card admin-attention-card"><div className="admin-card-heading"><div><h2>Staff Recommendations — Awaiting Admin Decision</h2><p>Review staff notes and accept or decline each recommendation. A recommendation decision does not itself confirm the reservation; complete the final booking action in Reservations.</p></div><b>{rows.length}</b></div>{message && <p className="admin-action-message">{message}</p>}<div className="admin-table-scroll"><table><thead><tr><th>Reservation</th><th>Customer / Package</th><th>Schedule</th><th>Validation warnings</th><th>Staff recommendation</th><th>Reviewer / submitted</th><th>Notes</th><th>Decision</th></tr></thead><tbody>{rows.map((row) => { const booking = row._booking as Row | undefined; const staff = row._staff as Row | undefined; const warnings = [!booking?.reservation_date && "Reservation date missing", (!booking?.start_time || !booking?.end_time) && "Schedule incomplete", !booking?.resource_key && "Resource not assigned"]; const activeWarnings = warnings.filter(Boolean); const notes = (row._staff_notes as Row[] | undefined) ?? []; return <tr key={String(row.id)}><td>{show(booking?.reservation_code)}</td><td>{show((row._customer as Row | undefined)?.full_name ?? booking?.customer_id)}<small>{show((row._package as Row | undefined)?.name ?? booking?.package_id)}</small></td><td>{show(booking?.reservation_date)}<small>{show(booking?.start_time)}–{show(booking?.end_time)} · {show(booking?.resource_key)}</small></td><td>{activeWarnings.length ? activeWarnings.join(" · ") : "No basic schedule warnings"}</td><td><Value label="status" value={row.recommendation}/><small>{show(row.reason)}</small></td><td>{show(staff?.full_name)}<small>{show(row.created_at)}</small></td><td>{show(row.notes)}{notes.map((note,index)=><small key={index}>{show(note.note)}</small>)}</td><td><div className="admin-inline-actions"><button disabled={!booking || String(booking.status).toLowerCase() !== "pending"} onClick={() => void decide(row,"approve")} type="button">Accept Recommendation</button><button onClick={() => void decide(row,"reject")} type="button">Decline</button><button onClick={() => void decide(row,"return")} type="button">Return to Staff</button></div></td></tr>; })}</tbody></table>{!rows.length && <div className="admin-empty"><strong>No decisions waiting</strong><p>New staff recommendations will be listed here.</p></div>}</div></section>;
}

function ScheduleProposalsView() {
  const [rows, setRows] = useState<Row[]>([]); const [message, setMessage] = useState("");
  const load = useCallback(async () => {
    const { data, error } = await supabase.from("evently_schedule_proposals").select("*").eq("proposal_state", "pending").order("created_at", { ascending: true });
    if (error) { setMessage(error.message); return; }
    const [reservations, profiles] = await Promise.all([supabase.from("reservations").select("id,reservation_code,customer_name,package_name,reservation_date,status"), supabase.from("profiles").select("id,full_name")]);
    const bookings = (reservations.data ?? []) as Row[]; const people = (profiles.data ?? []) as Row[];
    setRows(((data ?? []) as Row[]).map((proposal) => ({ ...proposal, _booking: bookings.find((booking) => booking.id === proposal.reservation_id), _staff: people.find((person) => person.id === proposal.staff_id) })));
  }, []);
  useEffect(() => { void load(); const interval = window.setInterval(() => void load(), 30000); return () => window.clearInterval(interval); }, [load]);
  const decide = async (row: Row, accept: boolean) => {
    const reason = window.prompt(accept ? "Enter the reason to accept this schedule override:" : "Why is this schedule proposal being declined?")?.trim();
    if (!reason) return;
    if (accept && !window.confirm("Accept this proposal using the audited, conflict-checked schedule override?")) return;
    const { error } = await supabase.rpc("evently_admin_decide_schedule_proposal", { p_proposal_id: String(row.id), p_accept: accept, p_reason: reason });
    setMessage(error ? error.message : `Schedule proposal ${accept ? "accepted" : "declined"}.`);
    if (!error) { void load(); window.dispatchEvent(new Event("evently-admin-data-changed")); }
  };
  return <section className="admin-card admin-table-card admin-attention-card"><div className="admin-card-heading"><div><h2>Schedule Proposals</h2><p>Administrator acceptance runs the existing resource and conflict checks.</p></div><b>{rows.length}</b></div>{message && <p className="admin-action-message">{message}</p>}<div className="admin-table-scroll"><table><thead><tr><th>Reservation</th><th>Staff</th><th>Proposed schedule</th><th>Note</th><th>Actions</th></tr></thead><tbody>{rows.map((row) => { const booking = row._booking as Row | undefined; const staff = row._staff as Row | undefined; return <tr key={String(row.id)}><td>{show(booking?.reservation_code)}<small>{show(booking?.customer_name)} · {show(booking?.package_name)}</small></td><td>{show(staff?.full_name)}</td><td>{show(row.proposed_date)}<small>{show(row.proposed_start_time)}–{show(row.proposed_end_time)} · {show(row.proposed_resource_key)}</small></td><td>{show(row.note)}</td><td><div className="admin-inline-actions"><button onClick={() => void decide(row,true)} type="button">Accept</button><button onClick={() => void decide(row,false)} type="button">Decline</button></div></td></tr>; })}</tbody></table>{!rows.length && <div className="admin-empty"><strong>No schedule proposals</strong><p>Staff proposals will appear here for approval.</p></div>}</div></section>;
}

function CateringChangeRequestsPanel({ requests, onChanged, canManage }: { requests: Row[]; onChanged?: () => void | Promise<void>; canManage: boolean }) {
  const [feedback, setFeedback] = useState("");
  const decide = async (request: Row, decision: "approved" | "rejected") => {
    if (!canManage) return;
    const note = window.prompt(decision === "approved" ? "Administrator approval note:" : "Reason for declining this customer request:")?.trim();
    if (!note) return;
    const { error } = await supabase.rpc("evently_admin_decide_catering_change", {
      p_request_id: String(request.id), p_decision: decision, p_decision_note: note,
    });
    setFeedback(error ? error.message : `Catering request ${decision}.`);
    if (!error) {
      window.dispatchEvent(new Event("evently-admin-data-changed"));
      window.dispatchEvent(new Event("evently-customer-bookings-changed"));
      await onChanged?.();
    }
  };
  if (!requests.length) return null;
  return <section className="admin-detail-section"><h3>Catering cancellation / reschedule requests</h3>{requests.map((request) => <article className="admin-review-excerpt" key={String(request.id)}>
    <strong>{show(request.request_action)} · {show(request.request_status)}</strong>
    <span>Requested {show(request.requested_at)} · event {show(request.original_reservation_date)} {show(request.original_start_time)}</span>
    <p>{show(request.reason)}</p>
    {String(request.request_action) === "reschedule" && <small>Proposed: {show(request.proposed_reservation_date)} {show(request.proposed_start_time)}–{show(request.proposed_end_time)}</small>}
    {Boolean(request.decision_note) && <small>Administrator: {show(request.decision_note)}</small>}
    {canManage && String(request.request_status) === "pending" && <div className="admin-inline-actions"><button onClick={() => void decide(request,"approved")} type="button">Approve request</button><button onClick={() => void decide(request,"rejected")} type="button">Decline request</button></div>}
  </article>)}{feedback && <p className="admin-action-message" role="status">{feedback}</p>}</section>;
}


function ReviewsWorkspace() {
  const [reviews, setReviews] = useState<Row[]>([]);
  const [customers, setCustomers] = useState<Record<string, string>>({});
  const [schemaReady, setSchemaReady] = useState<boolean | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [message, setMessage] = useState("");
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState("All");
  const [serviceFilter, setServiceFilter] = useState("All");
  const [ratingFilter, setRatingFilter] = useState("All");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [decision, setDecision] = useState<"approved" | "flagged" | "rejected" | null>(null);
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [page, setPage] = useState(1);
  const pageSize = 10;
  const load = useCallback(async (silent = false) => {
    if (!silent) setLoading(true);
    try {
      const ready = await supabase.rpc("evently_review_features_ready");
      if (ready.error || ready.data !== true) {
        setSchemaReady(false);
        setLoadError(ready.error?.message ?? "Review database features are unavailable.");
        return;
      }
      setSchemaReady(true);
      const result = await supabase.from("reviews").select("*").order("created_at",{ascending:false}).limit(1000);
      if (result.error) { setLoadError(result.error.message); return; }
      const rows = (result.data ?? []) as Row[];
      const ids = [...new Set(rows.map(row=>String(row.customer_id ?? "")).filter(Boolean))];
      if (ids.length) {
        const profiles = await supabase.from("profiles").select("id,full_name").in("id",ids);
        if (!profiles.error) setCustomers(Object.fromEntries((profiles.data ?? []).map(row=>[row.id,String(row.full_name || "Customer")])));
      }
      setReviews(rows);
      setLoadError("");
    } catch (error) {
      setLoadError(error instanceof Error ? error.message : "Unable to load reviews.");
    } finally { setLoading(false); }
  }, []);
  useEffect(() => {
    void load();
    const reload = () => { void load(true); };
    const interval = window.setInterval(reload,30000);
    window.addEventListener("evently-admin-data-changed",reload);
    const channel = supabase.channel("evently-admin-reviews")
      .on("postgres_changes",{event:"*",schema:"public",table:"reviews"},reload).subscribe();
    return () => {window.clearInterval(interval);window.removeEventListener("evently-admin-data-changed",reload);void supabase.removeChannel(channel);};
  },[load]);

  const reviewText = (row:Row) => String(first(row,["review_text","comment","content"]) ?? "");
  const service = (row:Row) => String(row.service_category ?? "Uncategorized");
  const customer = (row:Row) => customers[String(row.customer_id ?? "")] ?? "Customer";
  const published = reviews.filter(row=>row.is_published === true && row.moderation_status === "approved");
  const awaiting = reviews.filter(row=>["pending","flagged"].includes(String(row.moderation_status ?? "pending")));
  const average = reviews.length ? reviews.reduce((sum,row)=>sum+Number(row.rating ?? 0),0)/reviews.length : 0;
  const services = [...new Set(reviews.map(service))].sort();
  const visible = reviews.filter(row=>{
    const term = search.trim().toLowerCase();
    const matches = !term || [customer(row),service(row),reviewText(row),String(row.id),String(row.reservation_id ?? "")].some(value=>value.toLowerCase().includes(term));
    const status = String(row.moderation_status ?? "pending");
    return matches && (statusFilter === "All" || status === statusFilter)
      && (serviceFilter === "All" || service(row) === serviceFilter)
      && (ratingFilter === "All" || Number(row.rating) === Number(ratingFilter))
      && (!dateFrom || String(row.created_at ?? "").slice(0,10)>=dateFrom)
      && (!dateTo || String(row.created_at ?? "").slice(0,10)<=dateTo);
  });
  const pages = Math.max(1,Math.ceil(visible.length/pageSize));
  const currentPage = Math.min(page,pages);
  const paginated = visible.slice((currentPage-1)*pageSize,currentPage*pageSize);
  const selected = reviews.find(row=>String(row.id)===selectedId) ?? null;
  const resetFilters=()=>{setSearch("");setStatusFilter("All");setServiceFilter("All");setRatingFilter("All");setDateFrom("");setDateTo("");setPage(1);};
  const startDecision = (row:Row,next:"approved"|"flagged"|"rejected")=>{
    setSelectedId(String(row.id));setDecision(next);setReason("");setMessage("");
  };
  const saveDecision = async () => {
    if (!selected || !decision || saving) return;
    if (decision !== "approved" && !reason.trim()) {setMessage("Please provide a reason for flagging or rejecting the review.");return;}
    setSaving(true);setMessage("");
    try {
      const {error} = await supabase.rpc("evently_admin_moderate_review",{
        p_review_id:String(selected.id),p_decision:decision,p_reason:decision==="approved"?null:reason.trim()
      });
      if (error) {setMessage(error.message);return;}
      setMessage(decision==="approved"?"Review published successfully.":decision==="rejected"?"Review rejected.":"Review flagged for further review.");
      setDecision(null);setReason("");
      await load(true);
      window.dispatchEvent(new Event("evently-admin-data-changed"));
    } catch (error) {setMessage(error instanceof Error?error.message:"Moderation failed.");}
    finally {setSaving(false);}
  };
  if (loading && schemaReady === null) return <LoadingState />;
  if (schemaReady === false) return <section className="admin-card admin-schema-note"><h2>Review management is unavailable</h2><p>{loadError}</p><button className="admin-secondary-button" onClick={()=>void load()} type="button">Retry connection</button></section>;
  return <div className="review-workspace">
    <div className="review-topline"><div><span className="review-eyebrow">CUSTOMER EXPERIENCE</span><h2>Review Management</h2><p>Read customer feedback, publish eligible reviews, and handle flagged submissions.</p></div><button className="admin-secondary-button" type="button" onClick={()=>void load()} disabled={loading}>{loading?"Refreshing…":"Refresh reviews"}</button></div>
    <div className="review-summary" aria-label="Review statistics">
      <article><span>Total reviews</span><strong>{reviews.length}</strong><small>Customer submissions</small></article>
      <article><span>Average rating</span><strong>{reviews.length?average.toFixed(1):"—"} <span aria-hidden="true">★</span></strong><small>Across all reviews</small></article>
      <article><span>Needs attention</span><strong>{awaiting.length}</strong><small>Pending or flagged</small></article>
      <article><span>Published</span><strong>{published.length}</strong><small>Visible customer feedback</small></article>
    </div>
    {loadError && <div className="review-notice" role="alert">{loadError}<button className="admin-secondary-button" type="button" onClick={()=>void load()}>Retry</button></div>}
    {message && <div className="review-notice" role="status">{message}<button type="button" aria-label="Dismiss message" onClick={()=>setMessage("")}>×</button></div>}
    <section className="admin-card review-records">
      <div className="review-records-head"><div><h3>Customer reviews</h3><p>{visible.length} matching {visible.length===1?"review":"reviews"}</p></div><button type="button" className="admin-quiet-button" onClick={resetFilters}>Clear filters</button></div>
      <div className="review-filters">
        <label className="review-search">Search reviews<input value={search} onChange={e=>{setSearch(e.target.value);setPage(1);}} type="search" placeholder="Customer, feedback or service" /></label>
        <label>Moderation<select value={statusFilter} onChange={e=>{setStatusFilter(e.target.value);setPage(1);}}><option value="All">All statuses</option><option value="pending">Pending</option><option value="flagged">Flagged</option><option value="approved">Approved</option><option value="rejected">Rejected</option></select></label>
        <label>Service<select value={serviceFilter} onChange={e=>{setServiceFilter(e.target.value);setPage(1);}}><option value="All">All services</option>{services.map(item=><option key={item} value={item}>{item}</option>)}</select></label>
        <label>Rating<select value={ratingFilter} onChange={e=>{setRatingFilter(e.target.value);setPage(1);}}><option value="All">All ratings</option>{[5,4,3,2,1].map(n=><option key={n} value={n}>{n} stars</option>)}</select></label>
        <label>From<input type="date" value={dateFrom} onChange={e=>{setDateFrom(e.target.value);setPage(1);}} /></label>
        <label>To<input type="date" min={dateFrom||undefined} value={dateTo} onChange={e=>{setDateTo(e.target.value);setPage(1);}} /></label>
      </div>
      <div className="review-table-scroll">
        <table><thead><tr><th>Customer / service</th><th>Rating</th><th>Customer feedback</th><th>Moderation</th><th>Submitted</th><th>Action</th></tr></thead><tbody>
          {paginated.map(row=><tr key={String(row.id)}>
            <td><strong>{customer(row)}</strong><small>{service(row)}</small></td>
            <td><span className="review-stars" aria-label={String(row.rating)+" out of 5 stars"}>{"★".repeat(Math.max(0,Math.min(5,Number(row.rating)||0)))}</span><small>{String(row.rating ?? "—")}/5</small></td>
            <td><p className="review-excerpt">{reviewText(row)||"Star rating only — no written feedback"}</p>{Boolean(row.sentiment_label) && <small>Sentiment: {String(row.sentiment_label)}</small>}</td>
            <td><span className={"review-status review-status--"+String(row.moderation_status??"pending")}>{String(row.moderation_status??"pending")}</span></td>
            <td>{show(row.created_at)}</td>
            <td><button type="button" className="admin-secondary-button" onClick={()=>{setSelectedId(String(row.id));setDecision(null);setMessage("");}}>View details</button></td>
          </tr>)}
        </tbody></table>
      </div>
      {!visible.length && <div className="admin-empty"><strong>No reviews found</strong><p>{reviews.length?"Try adjusting the search or filters.":"No customer reviews have been submitted yet."}</p></div>}
      {visible.length>pageSize && <div className="admin-pagination"><span>Showing {(currentPage-1)*pageSize+1}–{Math.min(currentPage*pageSize,visible.length)} of {visible.length}</span><div><button type="button" disabled={currentPage===1} onClick={()=>setPage(v=>Math.max(1,v-1))}>Previous</button><b>{currentPage} / {pages}</b><button type="button" disabled={currentPage===pages} onClick={()=>setPage(v=>Math.min(pages,v+1))}>Next</button></div></div>}
    </section>
    {selected && <div className="review-modal-backdrop" role="presentation" onMouseDown={e=>{if(e.target===e.currentTarget&&!saving){setSelectedId(null);setDecision(null);}}}>
      <section className="review-modal" role="dialog" aria-modal="true" aria-labelledby="review-modal-title">
        <div className="review-modal-header"><div><span className="review-eyebrow">REVIEW DETAILS</span><h3 id="review-modal-title">{customer(selected)}</h3><p>{service(selected)} · {show(selected.created_at)}</p></div><button type="button" aria-label="Close review details" disabled={saving} onClick={()=>{setSelectedId(null);setDecision(null);}}>×</button></div>
        <div className="review-modal-body"><div className="review-modal-badges"><span className="review-stars">{"★".repeat(Math.max(0,Math.min(5,Number(selected.rating)||0)))}</span><span className={"review-status review-status--"+String(selected.moderation_status??"pending")}>{String(selected.moderation_status??"pending")}</span></div>
          <h4>Customer feedback</h4><p className="review-fulltext">{reviewText(selected)||"This customer submitted a star rating without written feedback."}</p>
          {Boolean(selected.sentiment_label) && <p className="review-meta">Sentiment: {String(selected.sentiment_label)}{selected.sentiment_confidence!=null?" · "+Math.round(Number(selected.sentiment_confidence)*100)+"% confidence":""}</p>}
          {Boolean(selected.moderation_reason) && <p className="review-meta"><strong>Previous moderation note:</strong> {String(selected.moderation_reason)}</p>}
          <p className="review-meta">Publication: {selected.is_published===true?"Published":"Not published"}</p>
          <div className="review-moderation"><h4>Moderation actions</h4><p>Publishing uses the existing server-side safety checks. Flagging and rejection require a reason.</p>
            <div className="review-action-row">
              <button type="button" disabled={saving||String(selected.moderation_status)==="approved"} onClick={()=>startDecision(selected,"approved")}>Approve & publish</button>
              <button type="button" disabled={saving} onClick={()=>startDecision(selected,"flagged")}>Flag for review</button>
              <button type="button" disabled={saving} onClick={()=>startDecision(selected,"rejected")}>Reject</button>
            </div>
            {decision && <div className="review-confirm"><strong>{decision==="approved"?"Publish this review?":decision==="flagged"?"Flag this review?":"Reject this review?"}</strong>
              {decision!=="approved" && <label>Moderation reason<textarea rows={3} value={reason} onChange={e=>setReason(e.target.value)} placeholder="Explain the decision for the audit record" /></label>}
              <div><button type="button" className="admin-secondary-button" disabled={saving} onClick={()=>{setDecision(null);setReason("");}}>Cancel</button><button type="button" disabled={saving||(decision!=="approved"&&!reason.trim())} onClick={()=>void saveDecision()}>{saving?"Saving…":"Confirm decision"}</button></div>
            </div>}
            {message && <p className="review-notice" role="status">{message}</p>}
          </div>
        </div>
      </section>
    </div>}
  </div>;
}

export default function AdminDashboard({ profile, path, navigate }: { profile: EventlyProfile; path: string; navigate: (to: string) => void }) {
  const normalizedPath = path === "calendar" ? "reservations" : path;
  const section = sections.some(([candidate]) => candidate === normalizedPath) ? normalizedPath : "dashboard";
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(() => localStorage.getItem("evently-admin-sidebar") === "collapsed");
  const [collapsedGroups, setCollapsedGroups] = useState<Record<string, boolean>>({});
  const [profileOpen, setProfileOpen] = useState(false);
  const [navCounts, setNavCounts] = useState<Record<string, number>>({});
  const title = sections.find(([candidate]) => candidate === section)?.[1] ?? "Dashboard";
  const go = (next: string) => { setSidebarOpen(false); navigate(`/admin/${next === "calendar" ? "reservations" : next}`); };
  const logout = async () => { await signOutUser(); navigate("/admin/login"); };
  const toggleSidebar = () => {
    setSidebarCollapsed((current) => {
      localStorage.setItem("evently-admin-sidebar", current ? "expanded" : "collapsed");
      return !current;
    });
  };
  const loadNavCounts = useCallback(async () => {
    const [reservations, payments, notifications, recommendations] = await Promise.all([
      supabase.from("reservations").select("id").eq("status", "pending"),
      supabase.from("payments").select("*"),
      supabase.from("notifications").select("id,is_read").eq("user_id", profile.id),
      supabase.from("evently_booking_recommendations").select("id").eq("review_state", "awaiting_admin"),
    ]);
    setNavCounts({
      reservations: reservations.data?.length ?? 0,
      "staff-approvals": recommendations.data?.length ?? 0,
      payments: (payments.data ?? []).filter((row) => String(first(row as Row, ["verification_status", "status"]) ?? "").toLowerCase() === "pending").length,
      notifications: (notifications.data ?? []).filter((row) => !row.is_read).length,
    });
  }, [profile.id]);
  useEffect(() => {
    void loadNavCounts();
    const refresh = () => { void loadNavCounts(); };
    window.addEventListener("evently-admin-data-changed", refresh);
    const poll = window.setInterval(refresh, 20000);
    return () => { window.removeEventListener("evently-admin-data-changed", refresh); window.clearInterval(poll); };
  }, [loadNavCounts]);

  let content: ReactNode;
  if (section === "dashboard") content = <><Overview go={go} /><RecommendationsView /><ScheduleProposalsView /></>;
  else if (section === "staff-approvals") content = <RecommendationsView />;
  else if (section === "reservations") content = <ReservationsView canManageReservations={profile.role === "owner" || profile.role === "admin"} go={go} />;
  else if (section === "messages") content = <MessagingInbox onViewReservation={(id) => go(`reservations?record=${encodeURIComponent(id)}`)} role="admin" />;
  else if (section === "reports") content = <Reports />;
  else if (section === "notifications") content = <NotificationsView go={go} />;
  else if (section === "activity-logs") content = <ActivityLogView />;
  else if (section === "settings") content = <Settings />;
  else if (section === "staff") content = <StaffManagement isOwner={profile.role === "owner"} />;
  else if (section === "reviews") content = <ReviewsWorkspace />;
  else if (section === "payments") content = <PaymentsWorkspace go={go} />;
  else if (["packages", "addons", "catering-menu"].includes(section)) content = <CatalogManagement section={section as "packages" | "addons" | "catering-menu"} />;
  else content = <DataTable go={go} section={section} />;

  return (
    <main className={`evently-admin ${sidebarCollapsed ? "admin-sidebar-collapsed" : ""}`}>
      {sidebarOpen && <button aria-label="Close navigation" className="admin-sidebar-overlay" onClick={() => setSidebarOpen(false)} type="button" />}
      <aside className={`admin-sidebar ${sidebarOpen ? "is-open" : ""}`}>
        <div className="admin-logo"><span>E</span><div><strong>EVENTLY</strong><small>Admin Operations</small></div></div>
        <nav aria-label="Admin navigation" className="admin-sidebar-navigation">{navigationGroups.map((group) => {
          const groupCollapsed = Boolean(collapsedGroups[group.label]);
          const groupId = `admin-nav-${group.label.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`;
          return <div className={`admin-nav-group ${groupCollapsed ? "is-collapsed" : ""}`} key={group.label}>
            <button aria-controls={groupId} aria-expanded={!groupCollapsed} aria-label={`${groupCollapsed ? "Expand" : "Collapse"} ${group.label}`} className="admin-nav-group-toggle" onClick={() => setCollapsedGroups((current) => ({ ...current, [group.label]: !current[group.label] }))} title={group.label} type="button"><span>{group.label}</span><Icon name="chevron" /></button>
            <div aria-hidden={groupCollapsed} className="admin-nav-group-items" id={groupId} inert={groupCollapsed}>
              <div>
              {group.paths.map((itemPath) => {
              const item = sections.find(([candidate]) => candidate === itemPath);
              if (!item) return null;
              return <button aria-current={section === itemPath ? "page" : undefined} aria-label={item[1]} className={section === itemPath ? "is-active" : ""} data-tooltip={item[1]} key={itemPath} onClick={() => go(itemPath)} type="button"><Icon name={item[2]} /><span>{item[1]}</span>{Boolean(navCounts[itemPath]) && <b aria-label={`${navCounts[itemPath]} pending`}>{navCounts[itemPath]}</b>}</button>;
              })}
              </div>
            </div>
          </div>;
        })}</nav>
        <div className="admin-sidebar-footer">
          <div><span>{profile.full_name?.slice(0, 1) || "A"}</span><p><strong>{profile.full_name || "Evently Admin"}</strong><small>{profile.role}</small></p></div>
          <button data-tooltip="Back to Website" onClick={() => navigate("/")} type="button"><Icon name="external" /><span>Back to Website</span></button>
          <button data-tooltip="Logout" onClick={logout} type="button"><Icon name="logout" /><span>Logout</span></button>
        </div>
        <button aria-label={sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"} className="admin-collapse-button" onClick={toggleSidebar} type="button"><Icon name="collapse" /><span>Collapse sidebar</span></button>
      </aside>
      <div className="admin-workspace">
        <header className="admin-topbar">
          <button className="admin-menu-button" onClick={() => setSidebarOpen(true)} type="button"><Icon name="list" /><span>Menu</span></button>
          <div className="admin-header-title"><span>Dashboard / {title}</span><strong>{title}</strong></div>
          <div className="admin-header-actions">
            <button aria-label="Open notifications" onClick={() => go("notifications")} type="button"><Icon name="bell" />{Boolean(navCounts["staff-approvals"]) && <b>{navCounts["staff-approvals"]}</b>}</button>
            <div className="admin-profile-menu">
              <button aria-expanded={profileOpen} onClick={() => setProfileOpen((current) => !current)} type="button"><span>{profile.full_name?.slice(0, 1) || "A"}</span><p><strong>{profile.full_name || "Evently Admin"}</strong><small>{profile.role}</small></p><Icon name="chevron" /></button>
              {profileOpen && <div><button onClick={() => { setProfileOpen(false); go("settings"); }} type="button">Account settings</button><button onClick={() => { setProfileOpen(false); void logout(); }} type="button">Logout</button></div>}
            </div>
          </div>
        </header>
        <div className="admin-content">
          <div className="admin-page-heading"><div><span>{section === "dashboard" ? new Date().toLocaleDateString("en-PH", { weekday: "long", month: "long", day: "numeric", year: "numeric" }) : "Evently Operations"}</span><h1>{section === "dashboard" ? `Welcome back, ${profile.full_name?.split(" ")[0] || "Admin"}` : title}</h1><p>{section === "dashboard" ? "Here is what needs your attention across Venice operations today." : pageDescriptions[section]}</p></div></div>
          {content}
        </div>
      </div>
    </main>
  );
}
