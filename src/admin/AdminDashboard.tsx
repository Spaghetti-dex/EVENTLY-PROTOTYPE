import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { EventlyProfile } from "../lib/supabase";
import { eventlyFunctionBaseUrl, signOutUser, supabase } from "../lib/supabase";

type Row = Record<string, unknown>;
type ScheduleResourceOption = { label: string; location: string; type: string; value: string };
type LoadState = "loading" | "ready" | "error";

const sections = [
  ["dashboard", "Overview", "grid"],
  ["reservations", "Reservations", "calendar"],
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
  ["activity-logs", "Activity Logs", "clock"],
  ["settings", "Settings", "settings"],
] as const;

const cateringMenuCategories = ["Beef", "Pork", "Chicken", "Seafood", "Vegetable", "Pasta / Pancit", "Dessert", "Drinks"];

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
    { label: "Package", keys: ["package_name", "package_id"] },
    { label: "Variant", keys: ["_package_variant", "package_variant"] },
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
  { label: "Overview", paths: ["dashboard", "notifications"] },
  { label: "Booking Management", paths: ["reservations", "orders"] },
  { label: "Business Management", paths: ["packages", "catering-menu", "addons", "customers", "staff"] },
  { label: "Finance & Insights", paths: ["payments", "reports", "reviews"] },
  { label: "System", paths: ["activity-logs", "settings"] },
];

const pageDescriptions: Record<string, string> = {
  dashboard: "Monitor reservations, payments, and business activity in one place.",
  reservations: "Review booking details, payment progress, and reservation status.",
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
      ? ["orders", "reservations", "profiles"] as const
      : ["reservations", "profiles"] as const;
  const results = await Promise.all(tableNames.map((name) => supabase.from(name).select("*").limit(500)));
  const failure = results.find((result) => result.error)?.error;
  if (failure) throw failure;
  const byTable = Object.fromEntries(tableNames.map((name, index) => [name, (results[index].data ?? []) as Row[]]));
  const profiles = byTable.profiles ?? [];
  const reservations = byTable.reservations ?? [];
  const profileName = (customerId: unknown) => first(
    profiles.find((profile) => String(profile.id) === String(customerId)) ?? {},
    ["full_name", "email"],
  );

  if (section === "reservations") {
    return (reservations.map((reservation) => ({
      ...reservation,
      _customer_name: first(reservation, ["customer_name"]) ?? profileName(reservation.customer_id),
    })) as Row[]).sort((left, right) => {
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
      };
    });
  }
  return (byTable.orders ?? []).map((order) => {
    const reservation = reservations.find((item) => String(item.id) === String(order.reservation_id));
    return {
      ...order,
      _customer_name: first(reservation ?? {}, ["customer_name"]) ?? profileName(order.customer_id),
      _reservation_code: first(reservation ?? {}, ["reservation_code", "id"]),
      _package_variant: first(reservation ?? {}, ["package_variant"]),
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

function Value({ value, label }: { value: unknown; label: string }) {
  const isStatus = /status|published|active|available|read/i.test(label);
  if (label === "Deposit %") return <>{value === null || value === undefined || value === "" ? "—" : `${show(value)}%`}</>;
  return isStatus
    ? <span className={`admin-status admin-status--${statusTone(value)}`}>{show(value, label)}</span>
    : <>{show(value, label)}</>;
}

type ActionMenuItem = { label: string; onSelect: () => void; disabled?: boolean };

function MoreActionsMenu({ label, items }: { label: string; items: ActionMenuItem[] }) {
  return (
    <details
      className="admin-action-menu"
      onKeyDown={(event) => {
        if (event.key !== "Escape") return;
        const details = event.currentTarget;
        details.open = false;
        details.querySelector("summary")?.focus();
      }}
    >
      <summary aria-label={`More actions for ${label}`} title={`More actions for ${label}`}>⋯</summary>
      <div className="admin-action-menu__items">
        {items.map((item) => (
          <button
            disabled={item.disabled}
            key={item.label}
            onClick={(event) => {
              const details = event.currentTarget.closest("details");
              if (details) details.open = false;
              item.onSelect();
            }}
            type="button"
          >
            {item.label}
          </button>
        ))}
      </div>
    </details>
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

function ReservationsView({ go }: { go: (path: string) => void }) {
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
                      { label: "View Details", onSelect: () => setSelected(row) },
                      { label: "View Customer", onSelect: () => { if (row.customer_id) go(`customers?record=${encodeURIComponent(String(row.customer_id))}`); else setSelected(row); } },
                      { label: "View Payment", onSelect: () => setSelected(row) },
                      { label: "View Activity History", onSelect: () => setSelected(row) },
                      ...(normalizedStatus(row) === "pending" ? [{ label: "Edit Schedule", onSelect: () => { setScheduleEditTarget(String(row.id)); setSelected(row); } }] : []),
                    ]}
                  />
                </td>
              </tr>)}</tbody>
            </table>
          </div>
          {visible.length > pageSize && <div className="admin-pagination"><span>Showing {(page - 1) * pageSize + 1}–{Math.min(page * pageSize, visible.length)} of {visible.length}</span><div><button disabled={page === 1} onClick={() => setPage((current) => current - 1)} type="button">Previous</button><b>{page} / {pageCount}</b><button disabled={page === pageCount} onClick={() => setPage((current) => current + 1)} type="button">Next</button></div></div>}
        </>}
      </section>
      {selected && <DetailDrawer onChanged={load} onClose={() => { setSelected(null); setScheduleEditTarget(""); }} openScheduleEditor={scheduleEditTarget === String(selected.id)} row={selected} section="reservations" title={show(first(selected, ["reservation_code", "id"]))} />}
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
      ? ["All", "Beef", "Pork", "Chicken", "Seafood", "Vegetable", "Pasta", "Dessert", "Drinks"]
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
                      { label: "View Details", onSelect: () => setSelected(row) },
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
      {selected && <DetailDrawer row={selected} section={section} title={show(first(selected, columns[0]?.keys ?? ["id"]))} onChanged={load} onClose={() => setSelected(null)} />}
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
  const [adjustment, setAdjustment] = useState("");
  const [guestCapacity, setGuestCapacity] = useState(String(first(row, ["guest_capacity"]) ?? ""));
  const [depositPercentage, setDepositPercentage] = useState(String(first(row, ["deposit_percentage"]) ?? ""));
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
    if (guestCapacity && (!Number.isInteger(Number(guestCapacity)) || Number(guestCapacity) < 1)) {
      setMessage("Guest capacity must be a positive whole number.");
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
        guest_capacity: guestCapacity || null,
        deposit_percentage: depositPercentage || null,
        is_active: active,
      });
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
      if (!category.trim()) { setMessage("Enter a menu category."); return; }
    }

    setBusy(true);
    setMessage("");
    const result = entity === "menu_item"
      ? await supabase.rpc("evently_admin_update_catering_menu_item", { p_id: String(row.id ?? ""), p_patch: patch })
      : await supabase.rpc("admin_update_evently_catalog", { p_entity: entity, p_id: String(row.id ?? ""), p_patch: patch });
    setBusy(false);
    if (result.error) { setMessage(result.error.message); return; }
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
          <label>Name<input onChange={(event) => setName(event.target.value)} required value={name} /></label>
          {(entity === "package" || entity === "addon") && <label>Description<textarea onChange={(event) => setDescription(event.target.value)} rows={3} value={description} /></label>}
          <label>{entity === "menu_item" ? "Price per guest (PHP)" : "Current price (PHP)"}<input min="0" onChange={(event) => setPrice(event.target.value)} required step="0.01" type="number" value={price} /></label>
          <div className="admin-price-helper"><label>Optional adjustment (%)<input min="0" onChange={(event) => setAdjustment(event.target.value)} placeholder="For example, 5" step="0.01" type="number" value={adjustment} /></label><p>Suggested price: <strong>{money.format(suggestedPrice)}</strong></p><button onClick={() => setPrice(suggestedPrice.toFixed(2))} type="button">Use suggestion</button></div>
          {(entity === "package" || entity === "package_variant") && <label>Guest capacity<input min="1" onChange={(event) => setGuestCapacity(event.target.value)} placeholder="No limit" step="1" type="number" value={guestCapacity} /></label>}
          {entity === "package" && <label>Required deposit (%)<input max="100" min="0" onChange={(event) => setDepositPercentage(event.target.value)} placeholder="Not configured" step="0.01" type="number" value={depositPercentage} /></label>}
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
              <td data-label="Actions" onClick={(event) => event.stopPropagation()}><MoreActionsMenu label={label} items={[{ label: "Edit Details", onSelect: () => setEditing({ entity, row }) }, { label: "View Details", onSelect: () => setSelected(row) }]} /></td>
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
      : window.prompt("Optional payment review note:")?.trim() ?? "";
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
    setBusy(false);
    if (error) {
      setMessage(error.message);
      return;
    }
    const updated = {
      ...payment,
      [statusKey]: decision,
      rejection_reason: decision === "rejected" ? reason : null,
      review_notes: reason || null,
      reviewed_at: new Date().toISOString(),
    };
    onReviewed?.(updated);
    setStatus(decision);
    setMessage(decision === "verified" ? "Payment proof verified for booking review." : "Payment proof rejected; the customer may submit corrected proof.");
    window.dispatchEvent(new Event("evently-admin-data-changed"));
    window.dispatchEvent(new Event("evently-customer-bookings-changed"));
  };

  return <article className="admin-payment-review-card">
    <header><div><strong>{show(first(payment, ["reference_number", "id"]))}</strong><small>{show(first(payment, ["method", "payment_method"]), "method")} · {show(first(payment, ["submitted_at", "created_at"]), "created_at")}</small></div><Value label="status" value={status} /></header>
    <dl><div><dt>Submitted amount</dt><dd>{show(first(payment, ["amount", "payment_amount"]), "amount")}</dd></div><div><dt>Customer</dt><dd>{show(first(payment, ["_customer_name", "customer_name", "customer_id"]))}</dd></div><div><dt>Demo mode</dt><dd>{payment.demo_mode === true ? "Demo — no actual money transfer" : "Manual payment proof"}</dd></div><div><dt>Reviewed</dt><dd>{first(payment, ["reviewed_at", "verified_at"]) ? `${show(first(payment, ["reviewed_at", "verified_at"]), "created_at")} · ${show(first(payment, ["reviewed_by", "verified_by"]))}` : "Not reviewed"}</dd></div></dl>
    {proofLoading && <p className="admin-payment-proof-missing">Loading private receipt for review…</p>}
    {proofPath && signedUrl && isImage && <a className="admin-payment-proof-preview" href={signedUrl} rel="noreferrer" target="_blank"><img alt="Private payment receipt preview" src={signedUrl} /><span>Open full-size receipt</span></a>}
    {proofPath && signedUrl && !isImage && <a className="admin-proof-button" href={signedUrl} rel="noreferrer" target="_blank">View private receipt</a>}
    {!proofPath && <p className="admin-payment-proof-missing">Receipt proof is missing. This payment cannot be verified.</p>}
    {Boolean(first(payment, ["rejection_reason", "review_notes"])) && <p className="admin-payment-review-note"><strong>Review note:</strong> {show(first(payment, ["rejection_reason", "review_notes"]))}</p>}
    {status === "pending" && <div className="admin-payment-review-actions"><button disabled={busy || proofLoading || !signedUrl || !proofPath || !first(payment, ["reference_number"])} onClick={() => void review("verified")} type="button">{busy ? "Saving…" : proofLoading ? "Loading Receipt…" : "Verify Payment Proof"}</button><button className="is-danger" disabled={busy} onClick={() => void review("rejected")} type="button">Reject / Request Resubmission</button></div>}
    {message && <p className={`admin-action-message ${/failed|error|cannot|denied/i.test(message) ? "is-error" : ""}`} role="status">{message}</p>}
  </article>;
}

function DetailDrawer({ row, section, title, onClose, onChanged, openScheduleEditor = false, onEditCatalog }: { row: Row; section: string; title: string; onClose: () => void; onChanged?: () => void | Promise<void>; openScheduleEditor?: boolean; onEditCatalog?: (entity: CatalogEntity, row: Row) => void }) {
  const [actionState, setActionState] = useState<LoadState>("ready");
  const [actionMessage, setActionMessage] = useState("");
  const [relatedPayments, setRelatedPayments] = useState<Row[]>([]);
  const [relatedPaymentsLoading, setRelatedPaymentsLoading] = useState(false);
  const [relatedActivity, setRelatedActivity] = useState<Row[]>([]);
  const [customerReservations, setCustomerReservations] = useState<Row[]>([]);
  const [relatedVariants, setRelatedVariants] = useState<Row[]>([]);
  const [scheduleStart, setScheduleStart] = useState(String(first(row, ["start_time"]) ?? "").slice(0, 5));
  const [scheduleEnd, setScheduleEnd] = useState(String(first(row, ["end_time"]) ?? "").slice(0, 5));
  const [scheduleDate, setScheduleDate] = useState(String(first(row, ["reservation_date"]) ?? "").slice(0, 10));
  const [scheduleResource, setScheduleResource] = useState(String(first(row, ["resource_key"]) ?? ""));
  const [scheduleResources, setScheduleResources] = useState<ScheduleResourceOption[]>([]);
  const [scheduleResourceError, setScheduleResourceError] = useState("");
  const [schedulePersisted, setSchedulePersisted] = useState(true);
  const [scheduleEditing, setScheduleEditing] = useState(false);
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
  useEffect(() => {
    if (section !== "reservations" || !row.id) return;
    setRelatedPaymentsLoading(true);
    void Promise.all([
      supabase.from("payments").select("*").eq("reservation_id", row.id).order("created_at", { ascending: false }),
      supabase.from("admin_activity_logs").select("*").eq("entity_id", row.id).order("created_at", { ascending: false }),
    ]).then(([payments, activity]) => {
      setRelatedPaymentsLoading(false);
      if (payments.error) setActionMessage(payments.error.message);
      else setRelatedPayments(((payments.data ?? []) as Row[]).map((payment) => ({
        ...payment,
        _customer_name: first(row, ["customer_name", "_customer_name", "customer_id"]),
      })));
      if (!activity.error) setRelatedActivity((activity.data ?? []) as Row[]);
    });
  }, [row.id, section]);
  useEffect(() => {
    if (section !== "customers" || !row.id) return;
    supabase.from("reservations").select("*").eq("customer_id", row.id).order("created_at", { ascending: false })
      .then(({ data, error }) => {
        if (error) setActionMessage(error.message);
        else setCustomerReservations((data ?? []) as Row[]);
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
  const scheduleFixed = String(first(row, ["schedule_mode"]) ?? "").toLowerCase() === "fixed";
  const scheduleRequired = String(first(row, ["schedule_mode"]) ?? "admin_assign").toLowerCase() !== "untimed";
  const scheduleResourceRequired = String(first(row, ["resource_mode"]) ?? "exclusive").toLowerCase() !== "shared_capacity";
  const scheduleResourceVerified = scheduleResources.some((resource) => resource.value === scheduleResource);
  const scheduleComplete = !scheduleRequired || Boolean(
    schedulePersisted
    && scheduleDate
    && scheduleStart
    && scheduleEnd
    && scheduleStart !== scheduleEnd
    && (!scheduleResourceRequired || scheduleResourceVerified),
  );
  const customerComplete = Boolean(first(row, ["customer_name", "_customer_name", "customer_id"]));
  const packageComplete = Boolean(first(row, ["package_name", "package_id"]));
  const configuredDeposit = Number(first(row, ["deposit_amount"]) ?? 0);
  const requiredPayment = configuredDeposit > 0 ? configuredDeposit : Number(first(row, ["total_amount"]) ?? 0);
  const verifiedPayments = relatedPayments.filter((payment) => String(first(payment, ["verification_status", "status"]) ?? "").toLowerCase() === "verified");
  const verifiedAmount = verifiedPayments.reduce((total, payment) => total + Number(first(payment, ["amount", "payment_amount"]) ?? 0), 0);
  const verifiedProof = verifiedPayments.some((payment) => Number(first(payment, ["amount", "payment_amount"]) ?? 0) > 0 && Boolean(first(payment, ["reference_number"])) && Boolean(first(payment, ["proof_url"])));
  const paymentVerified = !relatedPaymentsLoading && verifiedProof && verifiedAmount >= requiredPayment;
  const approvalChecks = [
    { complete: customerComplete, label: "Customer information complete", missing: "Customer information is missing." },
    { complete: packageComplete, label: "Package is valid", missing: "A valid package is required." },
    { complete: Boolean(scheduleDate), label: "Reservation date selected", missing: "A reservation date is required." },
    { complete: !scheduleRequired || Boolean(scheduleDate && scheduleStart && scheduleEnd && scheduleStart !== scheduleEnd), label: "Schedule assigned", missing: "Schedule incomplete — assign start and end times." },
    { complete: !scheduleResourceRequired || scheduleResourceVerified, label: "Venue or resource assigned", missing: "Select a verified physical venue or resource." },
    { complete: schedulePersisted && scheduleComplete, label: "No scheduling conflicts", missing: "Save the schedule so the secure conflict check can run." },
    { complete: paymentVerified, label: "Required payment proof verified", missing: relatedPaymentsLoading ? "Loading linked payment submissions…" : "Submit and verify receipt proof for at least the required deposit before approval." },
  ];
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
    setScheduleResource(String(first(row, ["resource_key"]) ?? ""));
    setSchedulePersisted(!scheduleRequired || Boolean(storedStart && storedEnd));
    setScheduleEditing(openScheduleEditor);
  }, [openScheduleEditor, row, scheduleFixed, scheduleRequired, section]);
  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [onClose]);
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
      const service = String(first(row, ["service_type", "service"]) ?? "").toLowerCase();
      const packageCategory = String(first(row, ["package_category"]) ?? "").toLowerCase();
      const expectedType = service === "catering"
        ? "catering"
        : packageCategory === "event_venue"
          ? "venue"
          : String(first(row, ["package_name"]) ?? "").toLowerCase().includes("room")
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
      setScheduleResource((current) => configured.some((resource) => resource.value === current) ? current : "");
      if (scheduleResourceRequired && !configured.length) {
        setScheduleResourceError(`No active ${expectedType || "physical"} resources are configured. Add the real facility to evently_resources before scheduling this reservation.`);
      }
    };
    void loadResources();
    return () => { active = false; };
  }, [row, section]);
  const saveReservationSchedule = async () => {
    if (section !== "reservations" || actionState === "loading") return;
    if (!scheduleStart || !scheduleEnd || scheduleStart === scheduleEnd) {
      setActionState("error");
      setActionMessage("Enter distinct start and end times.");
      return;
    }
    if (scheduleResourceRequired && (!scheduleResource || !scheduleResources.some((resource) => resource.value === scheduleResource))) {
      setActionState("error");
      setActionMessage(scheduleResourceError || "Select the verified physical venue or resource before saving.");
      return;
    }
    setActionState("loading");
    setActionMessage("");
    const { error } = await supabase.rpc("evently_admin_set_reservation_schedule", {
      p_end_time: scheduleEnd,
      p_reservation_id: String(row.id ?? ""),
      p_resource_key: scheduleResource.trim(),
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
    setActionMessage("Reservation schedule saved and checked for confirmed conflicts.");
    await onChanged?.();
    window.dispatchEvent(new Event("evently-admin-data-changed"));
    window.dispatchEvent(new Event("evently-customer-bookings-changed"));
  };
  const approveBooking = async () => {
    if (section !== "reservations" || actionState === "loading" || currentStatus !== "pending") return;
    const missingCheck = approvalChecks.find((check) => !check.complete);
    if (missingCheck) {
      setActionState("error");
      setActionMessage(missingCheck.missing);
      return;
    }
    const venue = scheduleResource || show(first(row, ["resource_key"]));
    const reservationDate = scheduleDate || show(first(row, ["reservation_date"]), "reservation_date");
    const startTime = scheduleStart || show(first(row, ["start_time"]));
    const endTime = scheduleEnd || show(first(row, ["end_time"]));
    const scheduleVerified = window.confirm(
      `Verify this booking schedule before approval.\n\nVenue / resource: ${venue}\nDate: ${reservationDate}\nTime: ${startTime}–${endTime}\n\nSelect OK only if you personally verified the actual venue or resource and confirmed that this time slot does not conflict with another approved reservation.`,
    );
    if (!scheduleVerified) return;

    setActionState("loading");
    setActionMessage("");
    const reservationId = String(row.id ?? "");
    const { data, error } = await supabase.rpc("evently_admin_approve_booking", {
      p_reservation_id: reservationId,
      p_schedule_verified: true,
    });
    if (error) {
      setActionState("error");
      setActionMessage(error.message);
      return;
    }

    const returnedRow = Array.isArray(data) ? data[0] : data;
    const returnedStatus = returnedRow && typeof returnedRow === "object"
      ? first(returnedRow as Row, ["status"])
      : typeof returnedRow === "string" ? returnedRow : null;
    const saved = await supabase.from("reservations").select("status").eq("id", reservationId).single();
    if (saved.error) {
      setActionState("error");
      setActionMessage(`Approval was accepted, but the saved status could not be refreshed: ${saved.error.message}`);
      await onChanged?.();
      window.dispatchEvent(new Event("evently-admin-data-changed"));
      return;
    }
    const savedStatus = String(saved.data.status ?? returnedStatus ?? "").toLowerCase();
    setCurrentStatus(savedStatus);
    setActionState("ready");
    setActionMessage(`Booking status: ${savedStatus || "saved"}.`);
    await onChanged?.();
    window.dispatchEvent(new Event("evently-admin-data-changed"));
    window.dispatchEvent(new Event("evently-customer-bookings-changed"));
  };
  const detailValue = (key: string, value: unknown) => {
    if (section !== "reservations") return value;
    if (key === "status") return currentStatus;
    if (key === "start_time") return scheduleStart;
    if (key === "end_time") return scheduleEnd;
    if (key === "resource_key") return scheduleResource;
    return value;
  };
  const mutate = async (action: string) => {
    if (actionState === "loading") return;
    let reason: string | null = null;
    if (action === "cancelled" || action === "rejected") {
      reason = window.prompt(section === "payments"
        ? "Enter the payment rejection reason:"
        : "Enter the booking rejection or cancellation reason:")?.trim() ?? "";
      if (!reason) return;
    }
    if (!window.confirm(`Confirm ${action === "cancelled" ? "reject/cancel" : action} for this ${section.replace(/-/g, " ")} record?`)) {
      return;
    }
    setActionState("loading");
    setActionMessage("");
    const id = String(row.id ?? "");
    const request = section === "reservations"
      ? supabase.rpc("admin_transition_reservation", { p_reason: reason, p_reservation_id: id, p_status: action })
      : section === "orders"
        ? supabase.rpc("admin_transition_order", { p_order_id: id, p_status: action })
        : supabase.rpc("admin_review_payment", { p_decision: action, p_payment_id: id, p_reason: reason });
    const { error } = await request;
    if (error) {
      setActionState("error");
      setActionMessage(error.message);
      return;
    }
    setActionState("ready");
    setActionMessage("Saved to Supabase.");
    await onChanged?.();
    window.dispatchEvent(new Event("evently-admin-data-changed"));
  };
  return (
    <div className="admin-drawer-wrap">
      <button aria-label="Close details" className="admin-drawer-backdrop" onClick={onClose} type="button" />
      <aside aria-label={`${title} details`} aria-modal="true" className="admin-detail-drawer" role="dialog">
        <div className="admin-drawer-heading"><div><span>{sections.find(([path]) => path === section)?.[1]} details</span><h2>{title}</h2></div><button aria-label="Close details" onClick={onClose} type="button">Close</button></div>
        {[...grouped, { label: "Additional information", test: /.*/, entries: remaining }].filter((group) => group.entries.length).map((group) => <section className="admin-detail-section" key={group.label}><h3>{group.label}</h3><dl>{group.entries.map(([key, value]) => <div key={key}><dt>{key.replace(/_/g, " ")}</dt><dd><Value label={key} value={detailValue(key, value)} /></dd></div>)}</dl></section>)}
        {section === "reservations" && <section className="admin-detail-section"><h3>Payment submissions</h3>{relatedPaymentsLoading ? <p>Loading linked payment submissions…</p> : relatedPayments.length ? <div className="admin-payment-review-list">{relatedPayments.map((payment) => <PaymentReviewCard key={String(payment.id)} onReviewed={(updated) => setRelatedPayments((current) => current.map((item) => item.id === updated.id ? updated : item))} payment={payment} />)}</div> : <p>No payment proof has been submitted for this reservation.</p>}</section>}
        {section === "reservations" && <section className="admin-detail-section"><h3>Reservation history</h3>{relatedActivity.length ? <div className="admin-history-timeline">{relatedActivity.map((activity) => <div key={String(activity.id)}><i /><span><strong>{show(first(activity, ["action"]))}</strong><small>{show(first(activity, ["description"]))}</small><time>{show(first(activity, ["created_at"]), "created_at")}</time></span></div>)}</div> : <p>No administrative history has been recorded for this reservation yet.</p>}</section>}
        {section === "reservations" && currentStatus === "pending" && <section className="admin-approval-checklist"><div><span>Approval readiness</span><strong>{approvalChecks.every((check) => check.complete) ? "Ready for approval" : "Action required"}</strong></div>{approvalChecks.map((check) => <p className={check.complete ? "is-complete" : ""} key={check.label}><i>{check.complete ? "✓" : "!"}</i><span><strong>{check.label}</strong>{!check.complete && <small>{check.missing}</small>}</span></p>)}<small>Payment proof verification and exclusive-resource conflicts are checked securely again by the approval RPC.</small></section>}
        {section === "reservations" && currentStatus === "pending" && scheduleEditing && <section className="admin-workflow-actions admin-schedule-editor"><h3>Edit schedule</h3><p>{scheduleFixed ? "This package uses a fixed tour schedule. Times are locked to the configured package." : "Assign the agreed schedule. An end time earlier than the start time is treated as the following day."}</p><div className="admin-schedule-context"><span>Reservation</span><strong>{show(first(row, ["reservation_code", "id"]))}</strong><span>Package</span><strong>{show(first(row, ["package_name", "package_id"]))}</strong><span>Variant</span><strong>{show(first(row, ["package_variant", "package_variant_id"]))}</strong><span>Duration</span><strong>{durationLabel}</strong></div><label><span>Reservation date</span><input disabled type="date" value={scheduleDate} /></label>{scheduleResourceRequired ? <label><span>Physical venue or resource</span><select required onChange={(event) => { setScheduleResource(event.target.value); setSchedulePersisted(false); }} value={scheduleResource}><option value="">Select a configured resource</option>{scheduleResources.map((resource) => <option key={resource.value} value={resource.value}>{resource.label}{resource.location ? ` · ${resource.location}` : ""}</option>)}</select></label> : <p className="admin-schedule-shared">Shared pool schedule — no exclusive pool resource is assigned.</p>}{scheduleResourceError && <p className="admin-schedule-error" role="alert">{scheduleResourceError}</p>}<div><label><span>Start time</span><input disabled={scheduleFixed} onChange={(event) => { setScheduleStart(event.target.value); setSchedulePersisted(false); }} type="time" value={scheduleStart} /></label><label><span>End time</span><input disabled={scheduleFixed} onChange={(event) => { setScheduleEnd(event.target.value); setSchedulePersisted(false); }} type="time" value={scheduleEnd} /></label></div><div className="admin-schedule-actions"><button className="admin-secondary-action" disabled={actionState === "loading"} onClick={() => { setScheduleStart(String(first(row, ["start_time"]) ?? scheduleStart).slice(0, 5)); setScheduleEnd(String(first(row, ["end_time"]) ?? scheduleEnd).slice(0, 5)); setScheduleResource(String(first(row, ["resource_key"]) ?? "")); setSchedulePersisted(true); setScheduleEditing(false); }} type="button">Cancel</button>{scheduleResourceRequired && <button disabled={actionState === "loading" || Boolean(scheduleResourceError) || !scheduleResource || !scheduleStart || !scheduleEnd} onClick={() => void saveReservationSchedule()} type="button">{actionState === "loading" ? "Saving…" : "Save Schedule"}</button>}</div></section>}
        {section === "reservations" && <section className="admin-workflow-actions admin-drawer-actions"><h3>Reservation actions</h3>{currentStatus === "pending" && !approvalChecks.every((check) => check.complete) && <p>{approvalChecks.find((check) => !check.complete)?.missing ?? "Complete the approval checks first."}</p>}<div>{currentStatus === "pending" && <button className="admin-secondary-action" disabled={actionState === "loading"} onClick={() => setScheduleEditing(true)} type="button">Edit Schedule</button>}{currentStatus === "pending" && <button disabled={actionState === "loading" || !approvalChecks.every((check) => check.complete)} title={!approvalChecks.every((check) => check.complete) ? approvalChecks.find((check) => !check.complete)?.missing : undefined} onClick={() => void approveBooking()} type="button">{actionState === "loading" ? "Approving…" : "Approve Booking"}</button>}{!["cancelled", "rejected", "completed"].includes(currentStatus) && <button className="is-danger" disabled={actionState === "loading"} onClick={() => void mutate("cancelled")} type="button">Reject Booking</button>}{currentStatus === "confirmed" && <button disabled={actionState === "loading"} onClick={() => void mutate("completed")} type="button">Mark Completed</button>}<button className="admin-close-action" onClick={onClose} type="button">Close</button></div></section>}
        {section === "orders" && <section className="admin-workflow-actions"><h3>Order actions</h3><div>{currentStatus === "pending" && <button disabled={actionState === "loading"} onClick={() => void mutate("confirmed")} type="button">Confirm Order</button>}{currentStatus === "confirmed" && <button disabled={actionState === "loading"} onClick={() => void mutate("preparing")} type="button">Start Preparing</button>}{currentStatus === "preparing" && <button disabled={actionState === "loading"} onClick={() => void mutate("ready")} type="button">Mark Ready</button>}{currentStatus === "ready" && <button disabled={actionState === "loading"} onClick={() => void mutate("completed")} type="button">Mark Completed</button>}{!["cancelled", "completed"].includes(currentStatus) && <button className="is-danger" disabled={actionState === "loading"} onClick={() => void mutate("cancelled")} type="button">Cancel Order</button>}</div></section>}
        {section === "payments" && <section className="admin-detail-section"><h3>Payment review</h3><PaymentReviewCard onReviewed={(updated) => { setCurrentStatus(String(first(updated, statusKeys) ?? "").toLowerCase()); void onChanged?.(); }} payment={row} /></section>}
        {section === "packages" && <section className="admin-detail-section"><h3>Package variants</h3>{relatedVariants.length ? <dl>{relatedVariants.map((variant) => <div key={String(variant.id)}><dt>{show(first(variant, ["name"]))}</dt><dd>{show(first(variant, ["price"]), "price")} · {show(first(variant, ["guest_capacity"]))} guests · {first(variant, ["has_aircon"]) ? "Air-conditioned" : "Non-aircon"} <MoreActionsMenu label={String(first(variant, ["name"]) ?? "variant")} items={[{ label: "Edit Variant", disabled: !onEditCatalog, onSelect: () => onEditCatalog?.("package_variant", variant) }]} /></dd></div>)}</dl> : <p>No variants are linked to this package.</p>}</section>}
        {section === "customers" && <section className="admin-detail-section"><h3>Booking history</h3>{customerReservations.length ? <div className="admin-customer-bookings">{customerReservations.map((reservation) => <div key={String(reservation.id)}><span><strong>{show(first(reservation, ["reservation_code", "id"]))}</strong><small>{show(first(reservation, ["package_name", "service_type"]))}</small></span><time>{show(first(reservation, ["reservation_date"]), "reservation_date")}</time><Value label="status" value={first(reservation, ["status"])} /></div>)}</div> : <p>This customer has no reservation records visible under the current RLS policy.</p>}</section>}
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
    ["Total Reservations", data.reservations.length, "All bookings on record", "reservations", "calendar"],
    ["Pending Approvals", pendingReservations.length, "Awaiting review and approval", "reservations", "clock"],
    ["Confirmed Reservations", data.reservations.filter((row) => status(row) === "confirmed").length, "Upcoming confirmed bookings", "reservations", "star"],
    ["Today's Schedule", todaysBookings.length, "Bookings scheduled today", "calendar", "calendar"],
    ["Pending Payments", pendingPayments.length, "Awaiting secure verification", "payments", "card"],
    ["Revenue Collected", money.format(revenue), "Verified non-demo payments only", "payments", "chart"],
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
      <div className="admin-stat-grid">{cards.map(([label, value, description, path, icon]) => <button key={label} onClick={() => go(String(path))} type="button"><i><Icon name={String(icon)} /></i><span>{label}</span><strong>{value}</strong><small>{description}</small></button>)}</div>
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
      <div className="admin-chart-grid">
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
  return (
    <>
      <div className="admin-toolbar"><label className="admin-search"><span>Search notifications</span><div><Icon name="search" /><input onChange={(event) => setSearch(event.target.value)} placeholder="Search title or message…" value={search} /></div></label><button className="admin-quiet-button" onClick={() => void load()} type="button"><Icon name="refresh" /> Refresh</button></div>
      <section className="admin-card admin-notification-inbox"><div className="admin-card-heading"><div><h2>Notification inbox</h2><p>{rows.filter((row) => !first(row, ["is_read", "read_at"])).length} unread record{rows.filter((row) => !first(row, ["is_read", "read_at"])).length === 1 ? "" : "s"}</p></div></div>{visible.length ? <div>{visible.map((row, index) => { const unread = !first(row, ["is_read", "read_at"]); const type = String(first(row, ["type", "entity_type"]) ?? "Update"); const entityType = String(first(row, ["entity_type"]) ?? ""); return <article className={unread ? "is-unread" : ""} key={String(row.id ?? index)}><i><Icon name={entityType === "reservation" ? "calendar" : type.toLowerCase().includes("payment") ? "card" : "bell"} /></i><span><small>{type.replace(/_/g, " ")}</small><strong>{show(first(row, ["title", "subject"]))}</strong><p>{show(first(row, ["message", "body", "content"]))}</p><time>{show(first(row, ["created_at"]), "created_at")}</time></span>{entityType === "reservation" && <button onClick={() => go("reservations")} type="button">Open reservations</button>}</article>; })}</div> : <div className="admin-empty"><strong>No notifications found</strong><p>Operational notifications allowed by the current RLS policy will appear here.</p></div>}</section>
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
    const [settings, auditResult] = await Promise.all([
      supabase.rpc("evently_admin_get_payment_accounts"),
      supabase.from("evently_payment_account_audit").select("id,changed_by,created_at,changed_methods").order("created_at", { ascending: false }).limit(20),
    ]);
    const failure = settings.error ?? auditResult.error;
    if (failure) { setError(failure.message); setState("error"); return; }
    const row = settings.data as (Row & { accounts?: unknown; demo_mode?: boolean; legacy_instructions?: Partial<LegacyPaymentInstructions>; updated_at?: string | null }) | null;
    const nextAccounts = Array.isArray(row?.accounts) ? row.accounts as PaymentAccount[] : [];
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
      gcash_instructions: String(row?.legacy_instructions?.gcash_instructions ?? ""),
      bank_transfer_instructions: String(row?.legacy_instructions?.bank_transfer_instructions ?? ""),
      cash_instructions: String(row?.legacy_instructions?.cash_instructions ?? ""),
    });
    setUpdatedAt(row?.updated_at ?? null);
    setDemoMode(row?.demo_mode !== false);
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

function Settings() {
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState("");
  const update = async () => {
    setMessage("Updating…");
    const { error } = await supabase.auth.updateUser({ password });
    setMessage(error ? error.message : "Password updated successfully.");
    if (!error) setPassword("");
  };
  return <div className="admin-settings-grid"><section className="admin-card admin-password-card"><span>Account security</span><h2>Change password</h2><p>Update the password for the currently authenticated Supabase account.</p><label>New password<input minLength={8} onChange={(event) => setPassword(event.target.value)} type="password" value={password} /></label><button disabled={password.length < 8} onClick={update} type="button">Update password</button>{message && <p role="status">{message}</p>}</section></div>;
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
  const [staffActivity, setStaffActivity] = useState<Row[]>([]);
  const [permissionPolicy, setPermissionPolicy] = useState<Row[]>([]);
  const [email, setEmail] = useState("");
  const [fullName, setFullName] = useState("");
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => {
    const [profiles, permissions, recommendations, policy] = await Promise.all([
      supabase.from("profiles").select("id,email,full_name,created_at,role,staff_active").eq("role", "staff").order("created_at", { ascending: false }),
      supabase.from("evently_staff_permissions").select("staff_id,permission,granted,updated_at"),
      supabase.from("evently_booking_recommendations").select("staff_id,recommendation,review_state,created_at"),
      supabase.from("evently_staff_permission_policy").select("permission,allowed_for_admins,updated_at"),
    ]);
    if (profiles.error || permissions.error || recommendations.error || policy.error) { setMessage((profiles.error ?? permissions.error ?? recommendations.error ?? policy.error)?.message ?? "Could not load staff."); return; }
    setStaff((profiles.data ?? []) as Row[]); setGrants((permissions.data ?? []) as Row[]); setStaffActivity((recommendations.data ?? []) as Row[]); setPermissionPolicy((policy.data ?? []) as Row[]);
  }, []);
  useEffect(() => { void load(); }, [load]);
  const invite = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault(); setBusy(true); setMessage("");
    const { data } = await supabase.auth.getSession();
    const response = await fetch(`${eventlyFunctionBaseUrl}/staff/provision`, {
      method: "POST", headers: { Authorization: `Bearer ${data.session?.access_token ?? ""}`, "Content-Type": "application/json" },
      body: JSON.stringify({ email, full_name: fullName }),
    });
    const result = await response.json().catch(() => ({}));
    setBusy(false); setMessage(response.ok ? `Invitation sent to ${email}.` : String(result.error ?? "Staff invitation failed."));
    if (response.ok) { setEmail(""); setFullName(""); void load(); }
  };
  const setGrant = async (staffId: string, permission: string, granted: boolean) => {
    const { error } = await supabase.rpc("evently_manage_staff_permission", { p_staff_id: staffId, p_permission: permission, p_granted: granted });
    setMessage(error ? error.message : "Staff permission updated.");
    if (!error) void load();
  };
  const setActive = async (staffId: string, active: boolean) => {
    const { error } = await supabase.rpc("evently_admin_set_staff_active", { p_staff_id: staffId, p_active: active });
    setMessage(error ? error.message : `Staff access ${active ? "activated" : "deactivated"}.`);
    if (!error) void load();
  };
  const editStaff = async (member: Row) => {
    const full_name = window.prompt("Staff member name", String(member.full_name ?? ""))?.trim();
    if (!full_name) return;
    const { error } = await supabase.from("profiles").update({ full_name }).eq("id", member.id);
    setMessage(error ? error.message : "Staff profile updated.");
    if (!error) void load();
  };
  const setPolicy = async (permission: string, allowed: boolean) => {
    const { error } = await supabase.rpc("evently_owner_set_staff_permission_policy", { p_permission: permission, p_allowed: allowed });
    setMessage(error ? error.message : "Owner permission policy updated.");
    if (!error) void load();
  };
  return <>
    <section className="admin-card admin-table-card"><div className="admin-card-heading"><div><h2>Owner-defined staff permission policy</h2><p>Administrators can grant only capabilities the Owner enables here. Permissions default to disabled.</p></div></div><div className="admin-permission-policy">{staffPermissions.map(([permission,title])=>{const allowed=permissionPolicy.some((item)=>item.permission===permission&&item.allowed_for_admins===true);return <label key={permission}><span>{title}</span><input aria-label={`${title} allowed for administrators`} checked={allowed} disabled={!isOwner} onChange={(event)=>void setPolicy(permission,event.target.checked)} type="checkbox"/><small>{allowed?"Administrators may grant":"Disabled by Owner"}</small></label>;})}</div>{!isOwner&&<p className="admin-action-message">Only the Owner can change this policy.</p>}</section>
    <section className="admin-card admin-password-card"><span>Secure invitation</span><h2>Invite a staff member</h2><p>The Edge Function sends an Auth invitation and assigns the staff role server-side. No service credentials are sent to the browser.</p><form onSubmit={(event) => void invite(event)}><label>Full name<input required value={fullName} onChange={(event) => setFullName(event.target.value)}/></label><label>Email<input required type="email" value={email} onChange={(event) => setEmail(event.target.value)}/></label><button disabled={busy} type="submit">{busy ? "Sending invitation…" : "Send invitation"}</button></form>{message && <p role="status">{message}</p>}</section>
    <section className="admin-card admin-table-card" style={{ marginTop: 16 }}><div className="admin-card-heading"><div><h2>Staff accounts and permissions</h2><p>{staff.length} current staff profiles</p></div><button className="admin-secondary-button" onClick={() => void load()} type="button">Refresh</button></div><div className="admin-table-scroll"><table><thead><tr><th>Staff member</th><th>Access</th><th>Recommendations / Recent activity</th>{staffPermissions.map(([, title]) => <th key={title}>{title}</th>)}</tr></thead><tbody>{staff.map((member) => { const actions = staffActivity.filter((item) => item.staff_id === member.id); return <tr key={String(member.id)}><td><strong>{show(member.full_name)}</strong><small>{show(member.email)}</small></td><td><button className="admin-row-action" onClick={() => void editStaff(member)} type="button">Edit profile</button><button className="admin-row-action" onClick={() => void setActive(String(member.id), member.staff_active === false)} type="button">{member.staff_active === false ? "Activate" : "Deactivate"}</button><small>{member.staff_active === false ? "Inactive" : "Active"}</small></td><td>{actions.length} recommendation{actions.length === 1 ? "" : "s"}<small>{actions[0] ? `${show(actions[0].recommendation)} · ${show(actions[0].created_at)}` : "No recommendations"}</small></td>{staffPermissions.map(([permission, title]) => { const granted = grants.some((grant) => grant.staff_id === member.id && grant.permission === permission && grant.granted === true); const allowed = permissionPolicy.some((item) => item.permission === permission && item.allowed_for_admins === true); return <td key={permission}><label className="admin-permission-toggle"><input aria-label={`${title} for ${show(member.full_name)}`} checked={granted} disabled={!allowed} onChange={(event) => void setGrant(String(member.id), permission, event.target.checked)} type="checkbox"/><span>{granted ? "Granted" : allowed ? "Off" : "Owner disabled"}</span></label></td>; })}</tr>; })}</tbody></table>{!staff.length && <div className="admin-empty"><strong>No staff accounts yet</strong><p>Send a secure invitation to add your first staff member.</p></div>}</div></section>
  </>;
}

function RecommendationsView() {
  const [rows, setRows] = useState<Row[]>([]);
  const [message, setMessage] = useState("");
  const load = useCallback(async () => {
    const { data: recommendations, error } = await supabase.from("evently_booking_recommendations").select("*").eq("review_state", "awaiting_admin").order("created_at", { ascending: true });
    if (error) { setMessage(error.message); return; }
    const [reservations, profiles, staffNotes] = await Promise.all([supabase.from("reservations").select("id,reservation_code,customer_name,package_name,reservation_date,start_time,end_time,resource_key,status"), supabase.from("profiles").select("id,full_name"), supabase.from("evently_reservation_staff_notes").select("reservation_id,note,created_at,staff_id").order("created_at", { ascending: false })]);
    const bookings = (reservations.data ?? []) as Row[]; const people = (profiles.data ?? []) as Row[]; const notesByReservation = (staffNotes.data ?? []) as Row[];
    setRows(((recommendations ?? []) as Row[]).map((rec) => ({ ...rec, _booking: bookings.find((booking) => booking.id === rec.reservation_id), _staff: people.find((person) => person.id === rec.staff_id), _staff_notes: notesByReservation.filter((note) => note.reservation_id === rec.reservation_id) })));
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
  return <section className="admin-card admin-table-card admin-attention-card"><div className="admin-card-heading"><div><h2>Awaiting Admin Decision</h2><p>Staff recommendations awaiting an authorized final outcome.</p></div><b>{rows.length}</b></div>{message && <p className="admin-action-message">{message}</p>}<div className="admin-table-scroll"><table><thead><tr><th>Reservation</th><th>Customer / Package</th><th>Schedule</th><th>Validation warnings</th><th>Staff recommendation</th><th>Reviewer / submitted</th><th>Notes</th><th>Decision</th></tr></thead><tbody>{rows.map((row) => { const booking = row._booking as Row | undefined; const staff = row._staff as Row | undefined; const warnings = [!booking?.reservation_date && "Reservation date missing", (!booking?.start_time || !booking?.end_time) && "Schedule incomplete", !booking?.resource_key && "Resource not assigned"]; const activeWarnings = warnings.filter(Boolean); const notes = (row._staff_notes as Row[] | undefined) ?? []; return <tr key={String(row.id)}><td>{show(booking?.reservation_code)}</td><td>{show(booking?.customer_name)}<small>{show(booking?.package_name)}</small></td><td>{show(booking?.reservation_date)}<small>{show(booking?.start_time)}–{show(booking?.end_time)} · {show(booking?.resource_key)}</small></td><td>{activeWarnings.length ? activeWarnings.join(" · ") : "No basic schedule warnings"}</td><td><Value label="status" value={row.recommendation}/><small>{show(row.reason)}</small></td><td>{show(staff?.full_name)}<small>{show(row.created_at)}</small></td><td>{show(row.notes)}{notes.map((note,index)=><small key={index}>{show(note.note)}</small>)}</td><td><div className="admin-inline-actions"><button disabled={!booking || String(booking.status).toLowerCase() !== "pending"} onClick={() => void decide(row,"approve")} type="button">Approve</button><button onClick={() => void decide(row,"reject")} type="button">Reject</button><button onClick={() => void decide(row,"return")} type="button">Return</button></div></td></tr>; })}</tbody></table>{!rows.length && <div className="admin-empty"><strong>No decisions waiting</strong><p>New staff recommendations will be listed here.</p></div>}</div></section>;
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
    const reason = accept ? null : window.prompt("Why is this schedule proposal being declined?")?.trim();
    if (!accept && !reason) return;
    const { error } = await supabase.rpc("evently_admin_decide_schedule_proposal", { p_proposal_id: String(row.id), p_accept: accept, p_reason: reason });
    setMessage(error ? error.message : `Schedule proposal ${accept ? "accepted" : "declined"}.`);
    if (!error) { void load(); window.dispatchEvent(new Event("evently-admin-data-changed")); }
  };
  return <section className="admin-card admin-table-card admin-attention-card"><div className="admin-card-heading"><div><h2>Schedule Proposals</h2><p>Administrator acceptance runs the existing resource and conflict checks.</p></div><b>{rows.length}</b></div>{message && <p className="admin-action-message">{message}</p>}<div className="admin-table-scroll"><table><thead><tr><th>Reservation</th><th>Staff</th><th>Proposed schedule</th><th>Note</th><th>Actions</th></tr></thead><tbody>{rows.map((row) => { const booking = row._booking as Row | undefined; const staff = row._staff as Row | undefined; return <tr key={String(row.id)}><td>{show(booking?.reservation_code)}<small>{show(booking?.customer_name)} · {show(booking?.package_name)}</small></td><td>{show(staff?.full_name)}</td><td>{show(row.proposed_date)}<small>{show(row.proposed_start_time)}–{show(row.proposed_end_time)} · {show(row.proposed_resource_key)}</small></td><td>{show(row.note)}</td><td><div className="admin-inline-actions"><button onClick={() => void decide(row,true)} type="button">Accept</button><button onClick={() => void decide(row,false)} type="button">Decline</button></div></td></tr>; })}</tbody></table>{!rows.length && <div className="admin-empty"><strong>No schedule proposals</strong><p>Staff proposals will appear here for approval.</p></div>}</div></section>;
}

function ReviewsWorkspace() {
  const [reviews, setReviews] = useState<Row[]>([]); const [packages, setPackages] = useState<Row[]>([]);
  const [filter, setFilter] = useState("All"); const [moderation, setModeration] = useState("All"); const [message, setMessage] = useState("");
  const [schemaReady, setSchemaReady] = useState<boolean | null>(null);
  const load = useCallback(async () => {
    const readiness = await supabase.rpc("evently_review_features_ready");
    if (readiness.error || readiness.data !== true) {
      setSchemaReady(false);
      setMessage("Review migrations are not applied or the schema is incomplete. Apply the pending Supabase migrations before using this workspace.");
      return;
    }
    setSchemaReady(true);
    const [reviewsResult, packagesResult] = await Promise.all([supabase.from("reviews").select("*").order("created_at", { ascending: false }).limit(1000), supabase.from("packages").select("id,name,service_type,package_category")]);
    if (reviewsResult.error) { setMessage(reviewsResult.error.message); return; }
    setReviews((reviewsResult.data ?? []) as Row[]); setPackages((packagesResult.data ?? []) as Row[]);
  }, []);
  useEffect(() => { void load(); }, [load]);
  const reviewText = (row: Row) => first(row,["review_text","comment","content"]);
  const serviceFor = (row: Row) => { const pack = packages.find((item) => item.id === row.package_id); const category = String(pack?.package_category ?? "").toLowerCase(); if (category.includes("event_venue")) return "Event Venues"; if (category.includes("room") || category.includes("accommodation")) return "Staycation / Rooms"; const service = String(pack?.service_type ?? ""); return service.toLowerCase().includes("resort") ? "Resort / Swimming Pool" : service || "Uncategorized"; };
  const visible = reviews.filter((row) => (filter === "All" || String(row.sentiment_label ?? "pending") === filter.toLowerCase()) && (moderation === "All" || String(row.moderation_status ?? "pending") === moderation.toLowerCase()));
  const published = reviews.filter((row) => row.is_published === true && row.moderation_status === "approved");
  const distribution = ["positive","neutral","negative"].map((sentiment) => ({ sentiment, count: published.filter((row) => row.sentiment_label === sentiment).length }));
  const average = published.length ? published.reduce((sum,row) => sum + Number(row.rating ?? 0),0) / published.length : 0;
  const months = Array.from({length: 6}, (_, index) => { const date = new Date(); date.setDate(1); date.setMonth(date.getMonth() - (5 - index)); return date; });
  const trendSeries = ["positive","neutral","negative"].map((sentiment) => ({ sentiment, points: months.map((month) => published.filter((row) => row.sentiment_label === sentiment && new Date(String(row.created_at)).getFullYear() === month.getFullYear() && new Date(String(row.created_at)).getMonth() === month.getMonth()).length) }));
  const trendMax = Math.max(...trendSeries.flatMap((series) => series.points), 1);
  const serviceNames = ["Catering","Resort / Swimming Pool","Staycation / Rooms","Event Venues"];
  const serviceRows = published.reduce<Record<string, number[]>>((totals, row) => {
    const service = serviceFor(row).toLowerCase();
    const category = service.includes("event_venue") || service.includes("venue") ? serviceNames[3]
      : service.includes("room") || service.includes("staycation") || service.includes("accommodation") ? serviceNames[2]
      : service.includes("catering") ? serviceNames[0] : service.includes("resort") || service.includes("pool") || service.includes("swim") ? serviceNames[1] : "Other";
    if (!totals[category]) totals[category] = [0,0,0];
    const index = ["positive","neutral","negative"].indexOf(String(row.sentiment_label));
    if (index >= 0) totals[category][index] += 1;
    return totals;
  }, {});
  const moderate = async (row: Row, decision: "approved" | "rejected" | "flagged") => { const reason = decision === "approved" ? null : window.prompt("Record a moderation reason:")?.trim(); if (decision !== "approved" && !reason) return; const { error } = await supabase.rpc("evently_admin_moderate_review", { p_review_id: String(row.id), p_decision: decision, p_reason: reason }); setMessage(error ? error.message : `Review ${decision}.`); if (!error) void load(); };
  const analyze = async (row: Row) => { const { data } = await supabase.auth.getSession(); const response = await fetch(`${eventlyFunctionBaseUrl}/reviews/analyze`, { method:"POST", headers:{ Authorization:`Bearer ${data.session?.access_token ?? ""}`, "Content-Type":"application/json" }, body:JSON.stringify({review_id:row.id}) }); const result = await response.json().catch(()=>({})); setMessage(response.ok ? `Analysis: ${result.sentiment} (${Math.round(result.confidence * 100)}% confidence).` : String(result.error ?? "Analysis unavailable.")); if (response.ok) void load(); };
  const max = Math.max(...distribution.map((item) => item.count), 1);
  const totalAnalyzed = distribution.reduce((sum, item) => sum + item.count, 0);
  if (schemaReady === null) return <LoadingState />;
  if (!schemaReady) return <section className="admin-card admin-schema-note"><span>Migration required</span><h2>Review moderation is not ready</h2><p>{message}</p><p>The application checks for the review edit, moderation, and sentiment schema before querying those fields.</p></section>;
  return <>
    {reviews.some((row) => !row.sentiment_label) && <section className="admin-card admin-attention-card"><div className="admin-card-heading"><div><h2>Sentiment analysis pending</h2><p>Unprocessed or failed analyses remain pending; retrying analyzes the stored review text.</p></div><b>{reviews.filter((row) => !row.sentiment_label).length}</b></div><div className="admin-review-pending-list">{reviews.filter((row) => !row.sentiment_label).slice(0, 6).map((row) => <article key={String(row.id)}><span><strong>{String(reviewText(row) ?? "").slice(0, 120)}</strong><small>{serviceFor(row)} · {show(row.created_at)}</small></span><button className="admin-row-action" onClick={() => void analyze(row)} type="button">Analyze / retry</button></article>)}</div></section>}
    <div className="admin-stat-grid"><article className="admin-card"><span>Published reviews</span><strong>{published.length}</strong></article><article className="admin-card"><span>Average rating</span><strong>{average ? average.toFixed(1) : "—"} ★</strong></article><article className="admin-card"><span>Moderation queue</span><strong>{reviews.filter((row) => ["pending","flagged"].includes(String(row.moderation_status))).length}</strong></article></div>
    <div className="admin-overview-grid" style={{ marginTop: 14 }}><section className="admin-card"><div className="admin-card-heading"><div><h2>Sentiment distribution</h2><p>From actual published review text with completed analysis.</p></div></div><div className="admin-donut-wrap"><svg aria-label="Sentiment distribution donut chart" role="img" viewBox="0 0 80 80"><circle cx="40" cy="40" r="30" fill="none" stroke="#edf1f1" strokeWidth="12"/><g transform="rotate(-90 40 40)">{distribution.map((item,index)=>{const circumference=188.5;const offset=distribution.slice(0,index).reduce((sum,previous)=>sum+previous.count/Math.max(totalAnalyzed,1)*circumference,0);return <circle key={item.sentiment} cx="40" cy="40" r="30" fill="none" stroke={["#148d88","#c9973d","#bc4a4f"][index]} strokeWidth="12" strokeDasharray={`${item.count/Math.max(totalAnalyzed,1)*circumference} ${circumference}`} strokeDashoffset={-offset}/>;})}</g><text x="40" y="39" textAnchor="middle" className="admin-donut-total">{totalAnalyzed}</text><text x="40" y="48" textAnchor="middle" className="admin-donut-label">ANALYZED</text></svg><div className="admin-sentiment-bars">{distribution.map((item) => <div key={item.sentiment}><span>{item.sentiment}</span><i><b style={{ width:`${item.count / max * 100}%` }}/></i><strong>{item.count}</strong></div>)}</div></div></section><section className="admin-card"><div className="admin-card-heading"><div><h2>Sentiment trends</h2><p>Monthly analyzed published reviews · last six months.</p></div></div>{published.some((row)=>row.sentiment_label) ? <div className="admin-sentiment-trend"><svg aria-label="Monthly review sentiment trends" role="img" viewBox="0 0 600 220" preserveAspectRatio="none"><path d="M35 15V185H590" fill="none" stroke="#dce5e5" strokeWidth="2"/>{trendSeries.map((series)=>{const points=series.points.map((value,index)=>`${45+index*105},${180-value/trendMax*150}`).join(" ");return <g key={series.sentiment}><polyline fill="none" points={points} stroke={series.sentiment === "positive" ? "#148d88" : series.sentiment === "neutral" ? "#c9973d" : "#bc4a4f"} strokeWidth="4"/>{series.points.map((value,index)=><circle key={index} cx={45+index*105} cy={180-value/trendMax*150} r="5" fill={series.sentiment === "positive" ? "#148d88" : series.sentiment === "neutral" ? "#c9973d" : "#bc4a4f"}/>)}</g>;})}</svg><div className="admin-sentiment-months">{months.map((month)=><span key={month.toISOString()}>{month.toLocaleDateString("en",{month:"short"})}</span>)}</div><div className="admin-sentiment-legend">{trendSeries.map((series)=><span key={series.sentiment}><i className={`is-${series.sentiment}`}/>{series.sentiment}</span>)}</div></div> : <div className="admin-chart-empty">Sentiment trends will appear after reviews are analyzed.</div>}</section></div>
    <section className="admin-card" style={{ marginTop:14 }}><div className="admin-card-heading"><div><h2>Reviews by service</h2><p>Analyzed review counts for actual linked services and packages.</p></div></div><div className="admin-review-services">{serviceNames.map((service,index)=>{const values=serviceRows[service]??[0,0,0];const total=values.reduce((sum,value)=>sum+value,0);return <article key={service}><strong>{service}</strong><span>{total} analyzed review{total===1?"":"s"}</span><div>{values.map((value,seriesIndex)=><i key={seriesIndex} style={{width:`${total ? value/total*100 : 0}%`,background:["#148d88","#c9973d","#bc4a4f"][seriesIndex]}} title={`${["Positive","Neutral","Negative"][seriesIndex]}: ${value}`}/>)}</div><small>Positive {values[0]} · Neutral {values[1]} · Negative {values[2]}</small></article>;})}</div></section>
    <div className="admin-overview-grid" style={{ marginTop: 14 }}><section className="admin-card"><div className="admin-card-heading"><div><h2>Recent customer feedback</h2><p>Latest published reviews with actual sentiment analysis.</p></div></div>{published.slice(0,4).map((row)=><article className="admin-review-excerpt" key={String(row.id)}><strong>{"★".repeat(Number(row.rating ?? 0))} · {String(row.sentiment_label ?? "Pending")}</strong><span>{serviceFor(row)} · {show(row.created_at)}</span><p>{String(reviewText(row) ?? "").slice(0,180)}</p></article>)}{!published.length && <div className="admin-chart-empty">No published reviews with data yet.</div>}</section><section className="admin-card"><div className="admin-card-heading"><div><h2>Moderation queue</h2><p>Pending and flagged customer submissions.</p></div></div>{reviews.filter((row)=>["pending","flagged"].includes(String(row.moderation_status))).slice(0,5).map((row)=><article className="admin-review-excerpt" key={String(row.id)}><strong>{show(row.moderation_status)} · {show(row.rating)} ★</strong><span>{serviceFor(row)} · {show(row.created_at)}</span><p>{String(reviewText(row) ?? "").slice(0,180)}</p></article>)}{!reviews.some((row)=>["pending","flagged"].includes(String(row.moderation_status))) && <div className="admin-chart-empty">No reviews are waiting for moderation.</div>}</section></div>
    <section className="admin-card admin-table-card" style={{ marginTop:14 }}><div className="admin-card-heading"><div><h2>Review moderation</h2><p>Sentiment describes text and does not determine publication eligibility.</p></div><div className="admin-inline-filters"><label>Sentiment<select value={filter} onChange={(event)=>setFilter(event.target.value)}><option>All</option><option>Positive</option><option>Neutral</option><option>Negative</option><option>Pending</option></select></label><label>Moderation<select value={moderation} onChange={(event)=>setModeration(event.target.value)}><option>All</option><option>Pending</option><option>Flagged</option><option>Approved</option><option>Rejected</option></select></label></div></div>{message && <p className="admin-action-message">{message}</p>}<div className="admin-table-scroll"><table><thead><tr><th>Customer</th><th>Service</th><th>Rating</th><th>Review</th><th>Sentiment</th><th>Moderation</th><th>Submitted</th><th>Actions</th></tr></thead><tbody>{visible.map((row)=><tr key={String(row.id)}><td>{show(row.customer_name ?? row.customer_id ?? row.user_id)}</td><td>{serviceFor(row)}</td><td>{show(row.rating)} ★</td><td className="admin-review-text">{String(reviewText(row) ?? "—")}</td><td>{show(row.sentiment_label)}{row.sentiment_confidence != null && <small>{Math.round(Number(row.sentiment_confidence)*100)}% confidence</small>}</td><td>{show(row.moderation_status)}</td><td>{show(row.created_at)}</td><td><div className="admin-inline-actions">{!row.sentiment_label && <button onClick={()=>void analyze(row)} type="button">Analyze</button>}<button onClick={()=>void moderate(row,"approved")} type="button">Publish</button><button onClick={()=>void moderate(row,"flagged")} type="button">Flag</button><button onClick={()=>void moderate(row,"rejected")} type="button">Reject</button></div></td></tr>)}</tbody></table>{!visible.length && <div className="admin-empty"><strong>No reviews match these filters</strong><p>Customer submissions will appear after the review migration is applied.</p></div>}</div></section>
  </>;
}

export default function AdminDashboard({ profile, path, navigate }: { profile: EventlyProfile; path: string; navigate: (to: string) => void }) {
  const normalizedPath = path === "calendar" ? "reservations" : path;
  const section = sections.some(([candidate]) => candidate === normalizedPath) ? normalizedPath : "dashboard";
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(() => localStorage.getItem("evently-admin-sidebar") === "collapsed");
  const [collapsedGroups, setCollapsedGroups] = useState<Record<string, boolean>>({});
  const [profileOpen, setProfileOpen] = useState(false);
  const [navCounts, setNavCounts] = useState<Record<string, number>>({});
  const title = sections.find(([candidate]) => candidate === section)?.[1] ?? "Overview";
  const go = (next: string) => { setSidebarOpen(false); navigate(`/admin/${next === "calendar" ? "reservations" : next}`); };
  const logout = async () => { await signOutUser(); navigate("/admin/login"); };
  const toggleSidebar = () => {
    setSidebarCollapsed((current) => {
      localStorage.setItem("evently-admin-sidebar", current ? "expanded" : "collapsed");
      return !current;
    });
  };
  const loadNavCounts = useCallback(async () => {
    const [reservations, payments, notifications] = await Promise.all([
      supabase.from("reservations").select("id").eq("status", "pending"),
      supabase.from("payments").select("*"),
      supabase.from("notifications").select("id,is_read"),
    ]);
    setNavCounts({
      reservations: reservations.data?.length ?? 0,
      payments: (payments.data ?? []).filter((row) => String(first(row as Row, ["verification_status", "status"]) ?? "").toLowerCase() === "pending").length,
      notifications: (notifications.data ?? []).filter((row) => !row.is_read).length,
    });
  }, []);
  useEffect(() => {
    void loadNavCounts();
    const refresh = () => { void loadNavCounts(); };
    window.addEventListener("evently-admin-data-changed", refresh);
    return () => window.removeEventListener("evently-admin-data-changed", refresh);
  }, [loadNavCounts]);

  let content: ReactNode;
  if (section === "dashboard") content = <><Overview go={go} /><RecommendationsView /><ScheduleProposalsView /></>;
  else if (section === "reservations") content = <ReservationsView go={go} />;
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
        <nav aria-label="Admin navigation">{navigationGroups.map((group) => {
          const groupCollapsed = Boolean(collapsedGroups[group.label]);
          return <div className={`admin-nav-group ${groupCollapsed ? "is-collapsed" : ""}`} key={group.label}>
            <button aria-expanded={!groupCollapsed} aria-label={`${groupCollapsed ? "Expand" : "Collapse"} ${group.label}`} className="admin-nav-group-toggle" onClick={() => setCollapsedGroups((current) => ({ ...current, [group.label]: !current[group.label] }))} title={group.label} type="button"><span>{group.label}</span><Icon name="chevron" /></button>
            {!groupCollapsed && group.paths.map((itemPath) => {
              const item = sections.find(([candidate]) => candidate === itemPath);
              if (!item) return null;
              return <button aria-current={section === itemPath ? "page" : undefined} aria-label={item[1]} className={section === itemPath ? "is-active" : ""} data-tooltip={item[1]} key={itemPath} onClick={() => go(itemPath)} type="button"><Icon name={item[2]} /><span>{item[1]}</span>{Boolean(navCounts[itemPath]) && <b aria-label={`${navCounts[itemPath]} pending`}>{navCounts[itemPath]}</b>}</button>;
            })}
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
            <button aria-label="Open notifications" onClick={() => go("notifications")} type="button"><Icon name="bell" /></button>
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
