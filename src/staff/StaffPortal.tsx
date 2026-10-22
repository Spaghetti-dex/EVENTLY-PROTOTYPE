import { useCallback, useEffect, useMemo, useState } from "react";
import {
  AlertTriangle, Bell, CalendarCheck2, CalendarDays, Check, CheckCircle2, ChevronDown,
  ChevronRight, Clock3, ClipboardCheck, ClipboardList, ExternalLink, Inbox, LayoutDashboard,
  LogOut, MapPin, Menu, MessageCircle, Package, RefreshCw, Search, Star, UserRound, Users, X,
  type LucideIcon,
} from "lucide-react";
import type { EventlyProfile } from "../lib/supabase";
import { signOutUser, supabase } from "../lib/supabase";
import { MessagingInbox } from "../messaging/MessagingViews";

type Row = Record<string, unknown>;
type Permission = { permission: string; granted: boolean };
type PortalSection = "dashboard" | "notifications" | "reservations" | "recommendations" | "orders" | "calendar" | "customers" | "reviews" | "profile" | "messages";
type PortalLink = { path: PortalSection; label: string; icon: LucideIcon };

const navigationGroups: Array<{ label: string; links: PortalLink[] }> = [
  { label: "Overview", links: [
    { path: "dashboard", label: "Dashboard", icon: LayoutDashboard },
    { path: "notifications", label: "Notifications", icon: Bell },
  ] },
  { label: "Booking Management", links: [
    { path: "reservations", label: "Reservations", icon: ClipboardList },
    { path: "recommendations", label: "Booking Recommendations", icon: ClipboardCheck },
    { path: "orders", label: "Orders", icon: Package },
    { path: "calendar", label: "Booking Calendar", icon: CalendarDays },
  ] },
  { label: "Operations", links: [
    { path: "customers", label: "Customers", icon: Users },
    { path: "reviews", label: "Reviews", icon: Star },
    { path: "profile", label: "My Profile", icon: UserRound },
    { path: "messages", label: "Messages", icon: MessageCircle },
  ] },
];
const allLinks = navigationGroups.flatMap((group) => group.links);
const titleFor = (path: PortalSection) => allLinks.find((link) => link.path === path)?.label ?? "Dashboard";
const label = (row: Row, ...keys: string[]) => String(keys.map((key) => row[key]).find((value) => value !== null && value !== undefined && value !== "") ?? "—");
const statusOf = (row: Row) => label(row, "status").toLowerCase();
const dateKey = (date: Date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
const formatDate = (value: unknown) => {
  if (!value) return "—";
  const raw = String(value).slice(0, 10);
  const parsed = new Date(`${raw}T12:00:00`);
  return Number.isNaN(parsed.getTime()) ? raw : parsed.toLocaleDateString("en-PH", { dateStyle: "medium" });
};
const timeValue = (value: unknown) => String(value ?? "").slice(0, 5);
const scheduleText = (row: Row) => {
  const start = timeValue(row.start_time);
  const end = timeValue(row.end_time);
  if (!start && !end) return "Time not assigned";
  if (!start || !end) return start || end;
  return `${start}–${end}${end <= start ? " · overnight" : ""}`;
};
const statusClass = (status: string) => {
  if (/confirm|complete|ready|approved/.test(status)) return "success";
  if (/pending|await|revision|prepar/.test(status)) return "warning";
  if (/cancel|reject|fail/.test(status)) return "danger";
  return "info";
};
const displayTime = (value: unknown) => {
  const time = timeValue(value);
  if (!time) return "Not assigned";
  const [hour, minute] = time.split(":").map(Number);
  if (!Number.isFinite(hour) || !Number.isFinite(minute)) return time;
  const meridiem = hour >= 12 ? "PM" : "AM";
  return `${hour % 12 || 12}:${String(minute).padStart(2, "0")} ${meridiem}`;
};

function StatusBadge({ value }: { value: unknown }) {
  const status = String(value ?? "unknown").replace(/_/g, " ");
  return <span className={`admin-status admin-status--${statusClass(status.toLowerCase())}`}>{status}</span>;
}

export default function StaffPortal({ profile, path, navigate }: { profile: EventlyProfile; path: string; navigate: (to: string, options?: { replace?: boolean }) => void }) {
  const section: PortalSection = allLinks.some((link) => link.path === path) ? path as PortalSection : "dashboard";
  const [rows, setRows] = useState<Row[]>([]);
  const [dashboardStats, setDashboardStats] = useState<Row | null>(null);
  const [orders, setOrders] = useState<Row[]>([]);
  const [permissions, setPermissions] = useState<Permission[]>([]);
  const [recommendations, setRecommendations] = useState<Row[]>([]);
  const [scheduleProposals, setScheduleProposals] = useState<Row[]>([]);
  const [staffNotes, setStaffNotes] = useState<Row[]>([]);
  const [notifications, setNotifications] = useState<Row[]>([]);
  const [reviews, setReviews] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState("");
  const [ordersError, setOrdersError] = useState("");
  const [notificationsError, setNotificationsError] = useState("");
  const [reviewsError, setReviewsError] = useState("");
  const [selected, setSelected] = useState<Row | null>(null);
  const [message, setMessage] = useState("");
  const [actionBusy, setActionBusy] = useState("");
  const [notes, setNotes] = useState("");
  const [reason, setReason] = useState("");
  const [scheduleStart, setScheduleStart] = useState("");
  const [scheduleEnd, setScheduleEnd] = useState("");
  const [scheduleResource, setScheduleResource] = useState("");
  const [availability, setAvailability] = useState<boolean | null>(null);
  const [availabilityError, setAvailabilityError] = useState("");
  const [profileName, setProfileName] = useState(profile.full_name ?? "");
  const [mobile, setMobile] = useState(profile.mobile_number ?? "");
  const [newPassword, setNewPassword] = useState("");
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [accountOpen, setAccountOpen] = useState(false);
  const can = (permission: string) => permissions.some((item) => item.permission === permission && item.granted);

  const refresh = useCallback(async (silent = false) => {
    if (!silent) setLoading(true);
    else setRefreshing(true);
    setError("");
    setOrdersError("");
    setNotificationsError("");
    setReviewsError("");
    try {
      const readiness = await supabase.rpc("evently_staff_permissions_ready");
      if (readiness.error || readiness.data !== true) {
        setRows([]); setDashboardStats(null); setOrders([]); setRecommendations([]); setScheduleProposals([]); setStaffNotes([]); setNotifications([]); setReviews([]);
        setError("Staff permissions are not configured in Supabase. Apply and verify the staff-role and dashboard migrations.");
        return;
      }
      const permissionResult = await supabase.from("evently_staff_permissions")
        .select("permission,granted").eq("staff_id", profile.id);
      if (permissionResult.error) {
        setError(`Staff permissions could not be loaded: ${permissionResult.error.message}`);
        return;
      }
      const grants = (permissionResult.data ?? []) as Permission[];
      setPermissions(grants);
      const has = (permission: string) => grants.some((item) => item.permission === permission && item.granted);
      const hasReservationAccess = has("view_reservations") || has("view_calendar");

      const [reservationResult, recommendationResult, proposalResult, noteResult, notificationResult, orderResult] = await Promise.all([
        hasReservationAccess ? supabase.rpc("evently_staff_list_reservations") : Promise.resolve(null),
        supabase.from("evently_booking_recommendations").select("*").eq("staff_id", profile.id).order("created_at", { ascending: false }),
        supabase.from("evently_schedule_proposals").select("*").eq("staff_id", profile.id).order("created_at", { ascending: false }),
        supabase.from("evently_reservation_staff_notes").select("*").eq("staff_id", profile.id).order("created_at", { ascending: false }),
        supabase.from("notifications").select("*").eq("user_id", profile.id).order("created_at", { ascending: false }).limit(100),
        has("view_orders") ? supabase.rpc("evently_staff_list_orders") : Promise.resolve(null),
      ]);

      if (reservationResult?.error) setError(`Reservations could not be loaded: ${reservationResult.error.message}`);
      else setRows((reservationResult?.data ?? []) as Row[]);
      if (recommendationResult.error) setError(`Recommendations could not be loaded: ${recommendationResult.error.message}`);
      else setRecommendations((recommendationResult.data ?? []) as Row[]);
      if (proposalResult.error) setError(`Schedule proposals could not be loaded: ${proposalResult.error.message}`);
      else setScheduleProposals((proposalResult.data ?? []) as Row[]);
      if (noteResult.error) setError(`Staff notes could not be loaded: ${noteResult.error.message}`);
      else setStaffNotes((noteResult.data ?? []) as Row[]);
      if (notificationResult.error) setNotificationsError(notificationResult.error.message);
      else setNotifications((notificationResult.data ?? []) as Row[]);
      if (orderResult?.error) setOrdersError(orderResult.error.message);
      else setOrders((orderResult?.data ?? []) as Row[]);
      if (hasReservationAccess) {
        const statsResult = await supabase.rpc("evently_staff_dashboard_stats");
        if (statsResult.error) setError(`Dashboard statistics could not be loaded: ${statsResult.error.message}`);
        else setDashboardStats((statsResult.data ?? null) as Row | null);
      } else {
        setDashboardStats(null);
      }

      if (has("moderate_reviews")) {
        const reviewReadiness = await supabase.rpc("evently_review_features_ready");
        if (reviewReadiness.error || reviewReadiness.data !== true) {
          setReviewsError("Review moderation is not configured in Supabase yet.");
        } else {
          const reviewResult = await supabase.from("reviews")
            .select("id,customer_id,reservation_id,rating,review_text,moderation_status,created_at")
            .order("created_at", { ascending: false }).limit(100);
          if (reviewResult.error) setReviewsError(reviewResult.error.message);
          else setReviews((reviewResult.data ?? []) as Row[]);
        }
      } else {
        setReviews([]);
      }
    } catch (refreshError) {
      setError(refreshError instanceof Error ? refreshError.message : "Staff dashboard data could not be loaded.");
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [profile.id]);

  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => {
    const interval = window.setInterval(() => void refresh(true), 60_000);
    const onDataChanged = () => void refresh(true);
    window.addEventListener("evently-admin-data-changed", onDataChanged);
    window.addEventListener("evently-customer-bookings-changed", onDataChanged);
    return () => {
      window.clearInterval(interval);
      window.removeEventListener("evently-admin-data-changed", onDataChanged);
      window.removeEventListener("evently-customer-bookings-changed", onDataChanged);
    };
  }, [refresh]);
  useEffect(() => {
    if (!selected) return;
    const latest = rows.find((row) => String(row.id) === String(selected.id));
    if (latest && latest !== selected) setSelected(latest);
  }, [rows]);
  useEffect(() => {
    if (!selected?.package_id || !selected.reservation_date) {
      setAvailability(null);
      setAvailabilityError("");
      return;
    }
    let active = true;
    setAvailability(null);
    setAvailabilityError("");
    void supabase.rpc("evently_check_availability", {
      p_package_id: String(selected.package_id),
      p_reservation_date: String(selected.reservation_date).slice(0, 10),
    }).then(({ data, error: availabilityQueryError }) => {
      if (!active) return;
      if (availabilityQueryError) setAvailabilityError(availabilityQueryError.message);
      else setAvailability(Boolean(data));
    });
    return () => { active = false; };
  }, [selected]);

  const today = dateKey(new Date());
  const pending = rows.filter((row) => statusOf(row) === "pending");
  const confirmed = rows.filter((row) => statusOf(row) === "confirmed");
  const todayRows = rows.filter((row) => String(row.reservation_date ?? "").slice(0, 10) === today && statusOf(row) !== "cancelled");
  const latestRecommendationByReservation = new Map<string, Row>();
  for (const recommendation of recommendations) {
    const reservationId = String(recommendation.reservation_id ?? "");
    if (reservationId && !latestRecommendationByReservation.has(reservationId)) {
      latestRecommendationByReservation.set(reservationId, recommendation);
    }
  }
  const awaitingMyRecommendation = pending.filter((row) => {
    const latest = latestRecommendationByReservation.get(String(row.id));
    const state = String(latest?.review_state ?? row.staff_recommendation_status ?? "");
    const reviewer = String(latest?.staff_id ?? row.staff_recommendation_staff_id ?? "");
    return !state || (state === "revision_requested" && reviewer === profile.id);
  });
  const recentRows = [...rows].sort((a, b) => String(b.created_at ?? "").localeCompare(String(a.created_at ?? ""))).slice(0, 8);
  const customerRows = useMemo(() => {
    const unique = new Map<string, Row>();
    for (const row of rows) if (row.customer_id && !unique.has(String(row.customer_id))) unique.set(String(row.customer_id), row);
    return Array.from(unique.values());
  }, [rows]);
  const unreadCount = notifications.filter((notification) => notification.is_read !== true).length;
  const recentActivity: Row[] = [
    ...recommendations.map((item): Row => ({ ...item, _kind: "Booking recommendation" })),
    ...scheduleProposals.map((item): Row => ({ ...item, _kind: "Schedule proposal" })),
  ].sort((a, b) => label(b, "created_at").localeCompare(label(a, "created_at"))).slice(0, 6);

  const go = (target: PortalSection) => {
    setSidebarOpen(false);
    setAccountOpen(false);
    navigate(`/staff/${target}`);
  };
  const logout = async () => {
    setMessage("");
    try {
      await signOutUser();
      navigate("/staff/login", { replace: true });
    } catch (logoutError) {
      setMessage(logoutError instanceof Error ? logoutError.message : "Unable to sign out. Try again.");
    }
  };
  const submitRecommendation = async (recommendation: "approve" | "reject") => {
    if (!selected || actionBusy) return;
    if (recommendation === "reject" && !reason.trim()) {
      setMessage("A reason is required when recommending rejection.");
      return;
    }
    const confirmed = window.confirm(`Submit a recommendation to ${recommendation} reservation ${label(selected, "reservation_code")}? An Admin/Owner makes the final decision.`);
    if (!confirmed) return;
    setActionBusy("recommendation");
    const { error: rpcError } = await supabase.rpc("evently_staff_submit_booking_recommendation", {
      p_reservation_id: String(selected.id), p_recommendation: recommendation,
      p_reason: recommendation === "reject" ? reason.trim() : null, p_notes: notes.trim() || null,
    });
    setActionBusy("");
    setMessage(rpcError ? rpcError.message : "Recommendation submitted for Admin/Owner review.");
    if (!rpcError) {
      setSelected(null); setReason(""); setNotes("");
      window.dispatchEvent(new Event("evently-admin-data-changed"));
      await refresh(true);
    }
  };
  const saveInternalNote = async () => {
    if (!selected || !notes.trim() || actionBusy) return;
    setActionBusy("note");
    const { error: noteError } = await supabase.rpc("evently_staff_add_reservation_note", { p_reservation_id: String(selected.id), p_note: notes.trim() });
    setActionBusy("");
    setMessage(noteError ? noteError.message : "Internal note saved.");
    if (!noteError) { setNotes(""); await refresh(true); }
  };
  const proposeSchedule = async () => {
    if (!selected || actionBusy) return;
    setActionBusy("schedule");
    const { error: proposalError } = await supabase.rpc("evently_staff_propose_reservation_schedule", {
      p_reservation_id: String(selected.id), p_date: String(selected.reservation_date).slice(0, 10),
      p_start_time: scheduleStart, p_end_time: scheduleEnd,
      p_resource_key: scheduleResource || String(selected.resource_key ?? ""), p_note: notes.trim() || null,
    });
    setActionBusy("");
    setMessage(proposalError ? proposalError.message : "Schedule change proposed for Admin/Owner review.");
    if (!proposalError) await refresh(true);
  };
  const flagReview = async (review: Row) => {
    if (actionBusy) return;
    setActionBusy("review");
    const { error: flagError } = await supabase.rpc("evently_admin_moderate_review", {
      p_review_id: String(review.id), p_decision: "flagged",
      p_reason: "Flagged for administrator oversight by staff moderator",
    });
    setActionBusy("");
    setMessage(flagError ? flagError.message : "Review flagged for Admin/Owner oversight.");
    if (!flagError) await refresh(true);
  };
  const updateProfile = async () => {
    const { error: updateError } = await supabase.from("profiles")
      .update({ full_name: profileName.trim(), mobile_number: mobile.trim() }).eq("id", profile.id);
    setMessage(updateError ? updateError.message : "Profile details updated.");
  };
  const updatePassword = async () => {
    const { error: passwordError } = await supabase.auth.updateUser({ password: newPassword });
    setMessage(passwordError ? passwordError.message : "Password updated.");
    if (!passwordError) setNewPassword("");
  };
  const markNotificationsRead = async () => {
    const unread = notifications.filter((item) => item.is_read !== true).map((item) => String(item.id));
    if (!unread.length) return;
    const { error: readError } = await supabase.rpc("mark_evently_notifications_read", { p_ids: unread });
    setNotificationsError(readError?.message ?? "");
    if (!readError) await refresh(true);
  };

  return <main className={`evently-admin staff-portal ${sidebarOpen ? "staff-sidebar-open" : ""}`}>
    {sidebarOpen && <button className="admin-sidebar-overlay" aria-label="Close staff navigation" onClick={() => setSidebarOpen(false)} type="button" />}
    <aside className={`admin-sidebar ${sidebarOpen ? "is-open" : ""}`}>
      <div className="admin-logo"><span>E</span><div><strong>EVENTLY</strong><small>Staff Operations</small></div></div>
      <nav aria-label="Staff Portal navigation">
        {navigationGroups.map((group) => <div className="admin-nav-group" key={group.label}>
          <span>{group.label}</span>
          {group.links.map(({ path: target, label: linkLabel, icon: Icon }) => <button
            aria-current={section === target ? "page" : undefined}
            className={section === target ? "is-active" : ""}
            data-tooltip={linkLabel}
            key={target}
            onClick={() => go(target)}
            type="button"
          ><Icon aria-hidden="true" size={17} /><span>{linkLabel}</span>{target === "notifications" && unreadCount > 0 && <b>{unreadCount}</b>}</button>)}
        </div>)}
      </nav>
      <div className="admin-sidebar-footer">
        <div><span>{profile.full_name?.slice(0, 1) || "S"}</span><p><strong>{profile.full_name || "Staff member"}</strong><small>Staff</small></p></div>
        <button data-tooltip="Back to Website" onClick={() => navigate("/")} type="button"><ExternalLink size={16}/><span>Back to Website</span></button>
        <button data-tooltip="Logout" onClick={() => void logout()} type="button"><LogOut size={16}/><span>Logout</span></button>
      </div>
    </aside>

    <div className="admin-workspace">
      <header className="admin-topbar staff-topbar">
        <button className="admin-menu-button" aria-label="Open staff navigation" onClick={() => setSidebarOpen(true)} type="button"><Menu size={19}/><span>Menu</span></button>
        <div className="admin-header-title"><span>EVENTLY / STAFF PORTAL · {new Date().toLocaleDateString("en-PH", { weekday: "short", month: "short", day: "numeric" })}</span><strong>{titleFor(section)}</strong></div>
        <div className="admin-header-actions">
          <button aria-label={`${unreadCount} unread notifications`} onClick={() => go("notifications")} type="button"><Bell size={18}/>{unreadCount > 0 && <b className="staff-notification-dot">{unreadCount}</b>}</button>
          <div className="admin-profile-menu">
            <button aria-expanded={accountOpen} onClick={() => setAccountOpen((open) => !open)} type="button">
              <span>{profile.full_name?.slice(0, 1) || "S"}</span>
              <p><strong>{profile.full_name || "Staff member"}</strong><small>Staff</small></p><ChevronDown size={15}/>
            </button>
            {accountOpen && <div><button onClick={() => go("profile")} type="button">My Profile</button><button onClick={() => void logout()} type="button">Logout</button></div>}
          </div>
        </div>
      </header>

      <div className="admin-content">
        <div className="admin-page-heading"><div><span>Staff Portal</span><h1>{section === "dashboard" ? `Welcome back, ${profile.full_name?.split(" ")[0] || "Team"}` : titleFor(section)}</h1><p>{section === "dashboard" ? "Manage daily reservations, review bookings, and coordinate event operations." : pageDescription(section)}</p></div><button className="admin-quiet-button staff-refresh" disabled={refreshing} onClick={() => void refresh(true)} type="button"><RefreshCw size={15}/>{refreshing ? "Refreshing…" : "Refresh"}</button></div>
        {error && <div className="admin-state admin-state--error staff-error" role="alert"><AlertTriangle size={20}/><p>{error}</p><button onClick={() => void refresh()} type="button">Retry</button></div>}
        {message && <div className={`admin-action-message staff-feedback-toast ${/error|failed|not available|not configured/i.test(message) ? "is-error" : ""}`} role="status">{message}<button aria-label="Dismiss message" onClick={() => setMessage("")} type="button"><X size={14}/></button></div>}

        {loading ? <LoadingState/> : <>
          {section === "dashboard" && <>
            <section className="admin-stat-grid staff-stat-grid">
              <StatCard icon={ClipboardList} title="Total Reservations" value={Number(dashboardStats?.total_reservations ?? rows.length)} detail="Reservations visible to your account"/>
              <StatCard icon={Clock3} title="Pending Reservations" value={Number(dashboardStats?.pending_reservations ?? pending.length)} detail="Awaiting operational review"/>
              <StatCard icon={CheckCircle2} title="Confirmed Reservations" value={Number(dashboardStats?.confirmed_reservations ?? confirmed.length)} detail="Confirmed bookings"/>
              <StatCard icon={CalendarCheck2} title="Today's Bookings" value={Number(dashboardStats?.today_bookings ?? todayRows.length)} detail="Not including cancelled bookings"/>
              <StatCard icon={ClipboardCheck} title="Awaiting My Recommendation" value={Number(dashboardStats?.awaiting_my_recommendation ?? awaitingMyRecommendation.length)} detail="Pending and returned for revision"/>
              <StatCard icon={Check} title="My Submitted Recommendations" value={Number(dashboardStats?.my_submitted_recommendations ?? recommendations.length)} detail="Your recommendation history"/>
            </section>
            <section className="admin-card admin-dashboard-table staff-dashboard-table">
              <div className="admin-card-heading"><div><h2>Recent Reservations</h2><p>Latest reservations available to your permissions.</p></div><button onClick={() => go("reservations")} type="button">View all <ChevronRight size={15}/></button></div>
              <ReservationTable rows={recentRows} recommendations={recommendations} onSelect={setSelected} pageSize={6}/>
            </section>
            <section className="admin-card admin-attention-card">
              <div className="admin-card-heading"><div><h2>Bookings Requiring Review</h2><p>Submit an operational recommendation; an Admin/Owner makes the final decision.</p></div><b>{awaitingMyRecommendation.length}</b></div>
              <div className="staff-review-list">{awaitingMyRecommendation.slice(0, 5).map((row) => <button key={String(row.id)} onClick={() => setSelected(row)} type="button"><span><strong>{label(row, "reservation_code")} · {label(row, "package_name")}</strong><small>{formatDate(row.reservation_date)} · {scheduleText(row)} · {label(row, "resource_name", "resource_key")}</small></span><ChevronRight size={17}/></button>)}{!awaitingMyRecommendation.length && <EmptyState title="No bookings awaiting your recommendation" detail="Pending bookings requiring your review will appear here."/>}</div>
            </section>
            <TodaySchedule rows={todayRows} onSelect={setSelected}/>
            <QuickActions onNavigate={go}/>
            <OperationalActivity rows={recentActivity}/>
          </>}

          {section === "reservations" && <section className="admin-card admin-table-card"><div className="admin-card-heading"><div><h2>Reservations</h2><p>Only bookings available under your staff permissions.</p></div></div><ReservationTable rows={rows} recommendations={recommendations} onSelect={setSelected}/></section>}
          {section === "recommendations" && <section className="admin-card admin-table-card"><div className="admin-card-heading"><div><h2>Bookings Requiring Review</h2><p>Review current reservation details and send a recommendation to the Admin/Owner.</p></div></div><ReservationTable rows={awaitingMyRecommendation} recommendations={recommendations} onSelect={setSelected}/></section>}
          {section === "calendar" && <CalendarPage rows={rows} onSelect={setSelected}/ >}
          {section === "orders" && <OrdersPage orders={orders} error={ordersError} canView={can("view_orders")}/>}
          {section === "customers" && <CustomersPage rows={customerRows} canView={can("view_customer_details")}/>}
          {section === "reviews" && <StaffReviewsPage reviews={reviews} error={reviewsError} canModerate={can("moderate_reviews")} onFlag={flagReview}/>}
          {section === "notifications" && <NotificationsPage rows={notifications} error={notificationsError} onRead={markNotificationsRead} onOpenReservation={(id) => { const row = rows.find((item) => String(item.id) === id); if (row) setSelected(row); else go("reservations"); }}/ >}
          {section === "profile" && <ProfilePage profile={profile} name={profileName} mobile={mobile} newPassword={newPassword} onName={setProfileName} onMobile={setMobile} onPassword={setNewPassword} onSave={() => void updateProfile()} onUpdatePassword={() => void updatePassword()}/>}
          {section === "messages" && <MessagingInbox role="staff" />}
        </>}
      </div>
    </div>

    {selected && <ReservationDrawer
      row={selected}
      permissions={permissions}
      profileId={profile.id}
      recommendations={recommendations}
      proposals={scheduleProposals}
      notes={staffNotes}
      internalNote={notes}
      rejectionReason={reason}
      startTime={scheduleStart || timeValue(selected.start_time)}
      endTime={scheduleEnd || timeValue(selected.end_time)}
      resourceKey={scheduleResource || String(selected.resource_key ?? "")}
      availability={availability}
      availabilityError={availabilityError}
      onClose={() => setSelected(null)}
      onInternalNote={setNotes}
      onRejectionReason={setReason}
      onStartTime={setScheduleStart}
      onEndTime={setScheduleEnd}
      onResourceKey={setScheduleResource}
      onSaveNote={() => void saveInternalNote()}
      onProposeSchedule={() => void proposeSchedule()}
      onRecommend={(decision) => void submitRecommendation(decision)}
      actionBusy={actionBusy}
    />}
  </main>;
}

function pageDescription(section: PortalSection) {
  const descriptions: Record<PortalSection, string> = {
    dashboard: "Manage daily reservations, review bookings, and coordinate event operations.",
    notifications: "Updates from real reservation, recommendation, and schedule events.",
    reservations: "Review permitted bookings and operational schedule details.",
    recommendations: "Track your submitted recommendations and review new pending bookings.",
    orders: "View non-financial order fulfillment information for authorized orders.",
    calendar: "See your operational schedule without exposing payment analytics.",
    customers: "Customer details are shown only when your Owner-approved permission allows them.",
    reviews: "Flag potentially inappropriate reviews for Admin/Owner moderation.",
    profile: "Manage your personal contact information and sign-in security.",
    messages: "Read and reply to fictional customer conversations in the Demo Chat inbox.",
  };
  return descriptions[section];
}

function StatCard({ icon: Icon, title, value, detail }: { icon: LucideIcon; title: string; value: number; detail: string }) {
  return <article className="admin-card staff-stat-card"><i><Icon size={20}/></i><span>{title}</span><strong>{value}</strong><small>{detail}</small></article>;
}

function LoadingState() {
  return <div className="admin-skeleton staff-dashboard-skeleton" aria-label="Loading staff dashboard"><span/><span/><span/><span/><span/><span/></div>;
}

function EmptyState({ title, detail }: { title: string; detail: string }) {
  return <div className="admin-empty staff-empty"><Inbox size={28}/><strong>{title}</strong><p>{detail}</p></div>;
}

function ReservationTable({ rows, recommendations, onSelect, pageSize = 10 }: { rows: Row[]; recommendations: Row[]; onSelect: (row: Row) => void; pageSize?: number }) {
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState("All");
  const [sort, setSort] = useState("newest");
  const [page, setPage] = useState(1);
  const statuses = ["All", ...new Set(rows.map((row) => String(row.status ?? "").toLowerCase()).filter(Boolean))];
  const filtered = rows.filter((row) => {
    const term = search.trim().toLowerCase();
    const searchable = [row.reservation_code, row.customer_name, row.package_name, row.service_type].map((value) => String(value ?? "").toLowerCase()).join(" ");
    return (!term || searchable.includes(term)) && (statusFilter === "All" || statusOf(row) === statusFilter);
  }).sort((a, b) => {
    const dateA = `${String(a.reservation_date ?? "")}T${timeValue(a.start_time)}`;
    const dateB = `${String(b.reservation_date ?? "")}T${timeValue(b.start_time)}`;
    return sort === "oldest" ? dateA.localeCompare(dateB) : dateB.localeCompare(dateA);
  });
  const pageCount = Math.max(1, Math.ceil(filtered.length / pageSize));
  const visible = filtered.slice((page - 1) * pageSize, page * pageSize);
  useEffect(() => { setPage(1); }, [search, statusFilter, sort, rows]);
  return <>
    <div className="staff-table-tools">
      <label className="admin-search"><span>Search reservations</span><div><Search className="admin-icon"/><input onChange={(event) => setSearch(event.target.value)} placeholder="Reference, customer, package…" value={search}/></div></label>
      <label><span>Status</span><select onChange={(event) => setStatusFilter(event.target.value)} value={statusFilter}>{statuses.map((status) => <option key={status} value={status}>{status === "All" ? status : status.replace(/_/g, " ")}</option>)}</select></label>
      <label><span>Sort date</span><select onChange={(event) => setSort(event.target.value)} value={sort}><option value="newest">Newest first</option><option value="oldest">Oldest first</option></select></label>
    </div>
    <div className="admin-table-scroll staff-reservation-scroll"><table><thead><tr><th>Booking Reference</th><th>Customer</th><th>Service / Package</th><th>Reservation Date</th><th>Time</th><th>Venue / Resource</th><th>Status</th><th>Staff Recommendation</th><th>Action</th></tr></thead><tbody>{visible.map((row) => {
      const recommendation = recommendations.find((item) => item.reservation_id === row.id);
      return <tr key={String(row.id)}>
        <td><strong>{label(row, "reservation_code")}</strong></td>
        <td>{row.customer_name ? label(row, "customer_name") : "Restricted"}</td>
        <td><strong>{label(row, "service_type")}</strong><small>{label(row, "package_name")}</small></td>
        <td>{formatDate(row.reservation_date)}</td>
        <td>{scheduleText(row)}</td>
        <td>{label(row, "resource_name", "resource_key")}</td>
        <td><StatusBadge value={row.status}/></td>
        <td>{recommendation ? <>{label(recommendation, "recommendation")}<small>{label(recommendation, "review_state")}</small></> : row.staff_recommendation ? <>{label(row, "staff_recommendation")}<small>{label(row, "staff_recommendation_status")}</small></> : "Not reviewed"}</td>
        <td><button className="admin-row-action" onClick={() => onSelect(row)} type="button">View Details</button></td>
      </tr>;
    })}</tbody></table>
    {!filtered.length && <EmptyState title="No reservations found" detail="Reservations allowed by your staff permissions will appear here."/>}</div>
    {filtered.length > pageSize && <div className="admin-pagination"><span>Showing {(page - 1) * pageSize + 1}–{Math.min(page * pageSize, filtered.length)} of {filtered.length}</span><div><button disabled={page === 1} onClick={() => setPage((current) => current - 1)} type="button">Previous</button><b>{page} / {pageCount}</b><button disabled={page === pageCount} onClick={() => setPage((current) => current + 1)} type="button">Next</button></div></div>}
  </>;
}

function TodaySchedule({ rows, onSelect }: { rows: Row[]; onSelect: (row: Row) => void }) {
  const entries = [...rows].sort((a, b) => timeValue(a.start_time).localeCompare(timeValue(b.start_time)));
  return <section className="admin-card staff-today-card"><div className="admin-card-heading"><div><h2>Today's Schedule</h2><p>{formatDate(dateKey(new Date()))} · {entries.length} operational booking{entries.length === 1 ? "" : "s"}</p></div><CalendarDays size={19}/></div>
    {entries.length ? <div className="staff-schedule-list">{entries.map((row) => <button key={String(row.id)} onClick={() => onSelect(row)} type="button"><time><strong>{displayTime(row.start_time)}</strong><small>{scheduleText(row)}</small></time><span><strong>{label(row, "reservation_code")} · {label(row, "package_name")}</strong><small>{label(row, "service_type")} · {label(row, "resource_name", "resource_key")}</small></span><StatusBadge value={row.status}/></button>)}</div> : <EmptyState title="No bookings scheduled today" detail="Today's permitted bookings will appear here."/>}
  </section>;
}

function QuickActions({ onNavigate }: { onNavigate: (path: PortalSection) => void }) {
  const actions: Array<{ path: PortalSection; label: string; detail: string; icon: LucideIcon }> = [
    { path: "reservations", label: "View Reservations", detail: "Search operational bookings", icon: ClipboardList },
    { path: "recommendations", label: "Review Pending Bookings", detail: "Send approval recommendations", icon: ClipboardCheck },
    { path: "calendar", label: "Open Booking Calendar", detail: "See upcoming schedule", icon: CalendarDays },
    { path: "orders", label: "View Orders", detail: "Operational order details", icon: Package },
    { path: "reviews", label: "View Reviews", detail: "Flag content for admin review", icon: Star },
  ];
  return <section className="staff-quick-actions"><div className="admin-card-heading"><div><h2>Quick Actions</h2><p>Open a staff-authorized workspace.</p></div></div><div>{actions.map(({ path, label: title, detail, icon: Icon }) => <button key={path} onClick={() => onNavigate(path)} type="button"><i><Icon size={18}/></i><span><strong>{title}</strong><small>{detail}</small></span><ChevronRight size={16}/></button>)}</div></section>;
}

function OperationalActivity({ rows }: { rows: Row[] }) {
  return <section className="admin-card admin-recent-card staff-activity-card"><div className="admin-card-heading"><div><h2>Recent Operational Activity</h2><p>Your recommendations and schedule proposals.</p></div></div>{rows.map((item) => <article key={`${label(item, "_kind")}-${label(item, "id")}`}><i>{label(item, "_kind") === "Booking recommendation" ? <ClipboardCheck size={16}/> : <CalendarDays size={16}/>}</i><span><strong>{label(item, "_kind")}: {label(item, "recommendation", "proposal_state")}</strong><small>{label(item, "review_state", "proposal_state")} · {formatDate(item.created_at)}</small></span><ChevronRight size={15}/></article>)}{!rows.length && <EmptyState title="No recent activity" detail="Your submitted recommendations and proposals will appear here."/>}</section>;
}

function CalendarPage({ rows, onSelect }: { rows: Row[]; onSelect: (row: Row) => void }) {
  const [dateFilter, setDateFilter] = useState("");
  const visible = [...rows].filter((row) => !dateFilter || String(row.reservation_date ?? "").slice(0, 10) === dateFilter)
    .filter((row) => statusOf(row) !== "cancelled")
    .sort((a, b) => `${a.reservation_date ?? ""}${timeValue(a.start_time)}`.localeCompare(`${b.reservation_date ?? ""}${timeValue(b.start_time)}`));
  return <section className="admin-card admin-table-card"><div className="admin-card-heading"><div><h2>Booking Calendar</h2><p>Scheduled bookings visible to your calendar permission.</p></div><label className="staff-date-filter"><span>Show date</span><input onChange={(event) => setDateFilter(event.target.value)} type="date" value={dateFilter}/></label></div>
    {visible.length ? <div className="staff-calendar-list">{visible.map((row) => <button key={String(row.id)} onClick={() => onSelect(row)} type="button"><time><strong>{formatDate(row.reservation_date)}</strong><small>{scheduleText(row)}</small></time><span><strong>{label(row, "reservation_code")} · {label(row, "service_type")} / {label(row, "package_name")}</strong><small>{label(row, "resource_name", "resource_key")}{row.customer_name ? ` · ${label(row, "customer_name")}` : ""}</small></span><StatusBadge value={row.status}/></button>)}</div> : <EmptyState title="No scheduled reservations" detail="No permitted reservations match this calendar view."/>}
  </section>;
}

function OrdersPage({ orders, error, canView }: { orders: Row[]; error: string; canView: boolean }) {
  const [search, setSearch] = useState("");
  if (!canView) return <EmptyState title="Order access is not granted" detail="Ask an administrator if your duties require operational order access."/>;
  if (error) return <div className="admin-state admin-state--error"><AlertTriangle size={20}/><p>{error}</p></div>;
  const visible = orders.filter((order) => !search.trim() || [order.order_code, order.reservation_code, order.package_name, order.customer_name].map((value) => String(value ?? "")).join(" ").toLowerCase().includes(search.trim().toLowerCase()));
  return <section className="admin-card admin-table-card"><div className="admin-card-heading"><div><h2>Operational Orders</h2><p>Financial totals and payment details are not available in the Staff Portal.</p></div></div><label className="admin-search"><span>Search orders</span><div><Search className="admin-icon"/><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Order or reservation reference…"/></div></label><div className="admin-table-scroll"><table><thead><tr><th>Order Reference</th><th>Booking Reference</th><th>Customer</th><th>Service / Package</th><th>Date</th><th>Time</th><th>Guests</th><th>Status</th></tr></thead><tbody>{visible.map((order)=><tr key={String(order.id)}><td>{label(order,"order_code")}</td><td>{label(order,"reservation_code")}</td><td>{order.customer_name ? label(order,"customer_name") : "Restricted"}</td><td>{label(order,"service_type")}<small>{label(order,"package_name")}</small></td><td>{formatDate(order.event_date)}</td><td>{scheduleText(order)}</td><td>{label(order,"guest_count")}</td><td><StatusBadge value={order.status}/></td></tr>)}</tbody></table>{!visible.length && <EmptyState title="No orders available" detail="Orders permitted to your account will appear here."/>}</div></section>;
}

function CustomersPage({ rows, canView }: { rows: Row[]; canView: boolean }) {
  const [search, setSearch] = useState("");
  if (!canView) return <EmptyState title="Customer-detail access is not granted" detail="Ask an administrator if your responsibilities require customer contact information."/>;
  const visible = rows.filter((row) => !search.trim() || [row.customer_name, row.customer_email, row.customer_phone, row.reservation_code].map((value) => String(value ?? "")).join(" ").toLowerCase().includes(search.trim().toLowerCase()));
  return <section className="admin-card admin-table-card"><div className="admin-card-heading"><div><h2>Customers on Permitted Reservations</h2><p>Only customers connected to reservations in your authorized view.</p></div></div><label className="admin-search"><span>Search customers</span><div><Search className="admin-icon"/><input onChange={(event)=>setSearch(event.target.value)} value={search} placeholder="Name, email, phone…"/></div></label><div className="admin-table-scroll"><table><thead><tr><th>Customer Name</th><th>Email</th><th>Phone</th><th>Booking Reference</th><th>Package</th><th>Date</th></tr></thead><tbody>{visible.map((row)=><tr key={`${String(row.customer_id)}-${String(row.id)}`}><td>{label(row,"customer_name")}</td><td>{label(row,"customer_email")}</td><td>{label(row,"customer_phone")}</td><td>{label(row,"reservation_code")}</td><td>{label(row,"package_name")}</td><td>{formatDate(row.reservation_date)}</td></tr>)}</tbody></table>{!visible.length && <EmptyState title="No customers found" detail="Authorized customer records will appear here."/>}</div></section>;
}

function StaffReviewsPage({ reviews, error, canModerate, onFlag }: { reviews: Row[]; error: string; canModerate: boolean; onFlag: (review: Row) => void }) {
  if (!canModerate) return <EmptyState title="Review access is not granted" detail="Ask an administrator if your duties include review moderation."/>;
  if (error) return <div className="admin-state admin-state--error"><AlertTriangle size={20}/><p>{error}</p></div>;
  return <section className="admin-card admin-table-card"><div className="admin-card-heading"><div><h2>Reviews Requiring Staff Attention</h2><p>Staff can flag a review for admin oversight but cannot publish or reject it.</p></div></div><div className="admin-table-scroll"><table><thead><tr><th>Review Text</th><th>Rating</th><th>Moderation</th><th>Submitted</th><th>Action</th></tr></thead><tbody>{reviews.map((review)=><tr key={String(review.id)}><td className="admin-review-text">{label(review,"review_text")}</td><td>{label(review,"rating")} ★</td><td>{label(review,"moderation_status")}</td><td>{formatDate(review.created_at)}</td><td><button className="admin-row-action" onClick={()=>onFlag(review)} type="button">Flag for Admin</button></td></tr>)}</tbody></table>{!reviews.length && <EmptyState title="No reviews requiring attention" detail="Reviews visible to your moderation permission will appear here."/>}</div></section>;
}

function NotificationsPage({ rows, error, onRead, onOpenReservation }: { rows: Row[]; error: string; onRead: () => void; onOpenReservation: (id: string) => void }) {
  if (error) return <section className="admin-card admin-state admin-state--error"><AlertTriangle size={20}/><p>Notifications could not be loaded: {error}</p></section>;
  const unread = rows.filter((row) => row.is_read !== true).length;
  return <section className="admin-card admin-notification-inbox"><div className="admin-card-heading"><div><h2>Operational Notifications</h2><p>{unread} unread notification{unread === 1 ? "" : "s"} addressed to this staff account.</p></div><button className="admin-quiet-button" disabled={!unread} onClick={onRead} type="button"><Check size={15}/> Mark all read</button></div>{rows.length ? <div>{rows.map((row)=><article className={row.is_read === true ? "" : "is-unread"} key={String(row.id)}><i><Bell size={17}/></i><span><small>{label(row,"type").replace(/_/g," ")}</small><strong>{label(row,"title")}</strong><p>{label(row,"message")}</p><time>{formatDate(row.created_at)}</time></span>{(row.entity_type === "reservation" || (Boolean(row.reservation_id) && !row.entity_type)) && <button onClick={()=>onOpenReservation(String(row.entity_id ?? row.reservation_id ?? ""))} type="button">Open Reservation</button>}</article>)}</div> : <EmptyState title="No operational notifications" detail="Notifications are created when a real reservation, recommendation, or schedule event affects your account."/>}</section>;
}

function ProfilePage({ profile, name, mobile, newPassword, onName, onMobile, onPassword, onSave, onUpdatePassword }: {
  profile: EventlyProfile; name: string; mobile: string; newPassword: string;
  onName: (value: string) => void; onMobile: (value: string) => void; onPassword: (value: string) => void;
  onSave: () => void; onUpdatePassword: () => void;
}) {
  return <div className="admin-settings-grid"><section className="admin-card admin-password-card"><span>Personal information</span><h2>My Profile</h2><label>Full name<input value={name} onChange={(event)=>onName(event.target.value)}/></label><label>Mobile number<input value={mobile} onChange={(event)=>onMobile(event.target.value)}/></label><label>Email<input disabled value={profile.email}/></label><label>Role<input disabled value="Staff"/></label><button onClick={onSave} type="button">Save profile</button></section><section className="admin-card admin-password-card"><span>Account security</span><h2>Change Password</h2><p>Password changes are handled by Supabase Auth.</p><label>New password<input minLength={8} type="password" value={newPassword} onChange={(event)=>onPassword(event.target.value)}/></label><button disabled={newPassword.length < 8} onClick={onUpdatePassword} type="button">Update password</button></section></div>;
}

function ReservationDrawer({ row, profileId, permissions, recommendations, proposals, notes, internalNote, rejectionReason, startTime, endTime, resourceKey, availability, availabilityError, actionBusy, onClose, onInternalNote, onRejectionReason, onStartTime, onEndTime, onResourceKey, onSaveNote, onProposeSchedule, onRecommend }: {
  profileId: string;
  row: Row; permissions: Permission[]; recommendations: Row[]; proposals: Row[]; notes: Row[];
  internalNote: string; rejectionReason: string; startTime: string; endTime: string; resourceKey: string;
  availability: boolean | null; availabilityError: string; actionBusy: string; onClose: () => void;
  onInternalNote: (value: string) => void; onRejectionReason: (value: string) => void;
  onStartTime: (value: string) => void; onEndTime: (value: string) => void; onResourceKey: (value: string) => void;
  onSaveNote: () => void; onProposeSchedule: () => void; onRecommend: (decision: "approve" | "reject") => void;
}) {
  const permission = (key: string) => permissions.some((grant) => grant.permission === key && grant.granted);
  const [termsAcceptance, setTermsAcceptance] = useState<Row | null>(null);
  const [termsLoading, setTermsLoading] = useState(false);
  useEffect(() => {
    if (!permission("view_reservations") || !row.id) { setTermsAcceptance(null); return; }
    let mounted = true;
    setTermsAcceptance(null);
    setTermsLoading(true);
    void supabase.from("evently_terms_acceptances")
      .select("accepted,accepted_at,terms_version").eq("reservation_id",row.id)
      .maybeSingle().then(({data}) => {
        if (mounted) {
          setTermsAcceptance((data as Row | null) ?? null);
          setTermsLoading(false);
        }
      });
    return () => { mounted = false; };
  }, [row.id, permissions]);
  const rowRecommendations = recommendations.filter((item) => item.reservation_id === row.id);
  const activeRecommendation = rowRecommendations[0];
  const recommendationState = String(activeRecommendation?.review_state ?? row.staff_recommendation_status ?? "");
  const recommendationStaff = String(activeRecommendation?.staff_id ?? row.staff_recommendation_staff_id ?? "");
  const canRecommend = statusOf(row) === "pending" && recommendationState !== "awaiting_admin"
    && (recommendationState !== "revision_requested" || recommendationStaff === profileId);
  return <div className="admin-drawer-wrap"><button className="admin-drawer-backdrop" onClick={onClose} aria-label="Close reservation details" type="button"/><aside className="admin-detail-drawer"><header className="admin-drawer-heading"><div><span>Staff Reservation Details</span><h2>{label(row,"reservation_code")}</h2></div><button onClick={onClose} type="button">Close</button></header>
    <section className="admin-detail-section"><h3>Booking and service</h3><dl>{[["Customer","customer_name"],["Customer email","customer_email"],["Service","service_type"],["Package","package_name"],["Date","reservation_date"],["Time","start_time"],["End","end_time"],["Venue / Resource","resource_name","resource_key"],["Guest count","guest_count"],["Special requests","special_requests"],["Booking status","status"]].map(([title,...keys])=><div key={title}><dt>{title}</dt><dd>{title === "Date" ? formatDate(row[keys[0]]) : title === "Time" || title === "End" ? displayTime(row[keys[0]]) : label(row,...keys)}</dd></div>)}</dl>
      {availability !== null && <p className={availability ? "staff-availability is-available" : "staff-availability is-unavailable"}>{availability ? <CheckCircle2 size={16}/> : <AlertTriangle size={16}/>} Package/date check: {availability ? "eligible" : "unavailable"}. Admin approval still performs final resource/time conflict validation.</p>}{availabilityError && <p className="staff-availability is-pending"><AlertTriangle size={16}/> Availability check failed: {availabilityError}</p>}
    </section>
    {permission("view_reservations") && <section className="admin-detail-section"><h3>Terms and Conditions agreement</h3><dl><div><dt>Status</dt><dd>{termsLoading ? "Checking…" : termsAcceptance?.accepted === true ? "Accepted" : "Not recorded"}</dd></div><div><dt>Terms version</dt><dd>{String(termsAcceptance?.terms_version ?? "—")}</dd></div><div><dt>Accepted at · Asia/Manila</dt><dd>{termsAcceptance?.accepted_at ? new Intl.DateTimeFormat("en-PH", {dateStyle:"medium",timeStyle:"short",timeZone:"Asia/Manila"}).format(new Date(String(termsAcceptance.accepted_at))) : "—"}</dd></div></dl></section>}
    <section className="admin-detail-section"><h3>Recommendation history</h3>{rowRecommendations.map((item)=><p key={String(item.id)}><strong>{label(item,"recommendation")}</strong> · {label(item,"review_state")} · {formatDate(item.created_at)}<br/>{label(item,"decision_note","reason","notes")}<small>Updated {formatDate(item.updated_at)}</small></p>)}{!rowRecommendations.length && <p>No recommendation has been submitted for this reservation.</p>}{proposals.filter((item)=>item.reservation_id===row.id).map((item)=><p key={String(item.id)}><strong>Schedule proposal: {label(item,"proposal_state")}</strong> · {displayTime(item.proposed_start_time)}–{displayTime(item.proposed_end_time)}<br/>{label(item,"decision_note","note")}</p>)}{notes.filter((item)=>item.reservation_id===row.id).map((item)=><p key={String(item.id)}><strong>Internal note</strong> · {label(item,"note")}<small>{formatDate(item.created_at)}</small></p>)}</section>
    {statusOf(row) === "pending" && <section className="admin-workflow-actions"><h3>Operational actions</h3>
      {permission("edit_reservation_details") && <><label>Internal booking note<textarea maxLength={3000} value={internalNote} onChange={(event)=>onInternalNote(event.target.value)} rows={3}/></label><button className="admin-secondary-action" disabled={!internalNote.trim() || Boolean(actionBusy)} onClick={onSaveNote} type="button">{actionBusy === "note" ? "Saving…" : "Save Internal Note"}</button></>}
      {permission("propose_schedule_changes") && <div className="admin-schedule-editor"><p>Propose a schedule change. Admin approval runs the configured schedule and conflict validation.</p><div><label>Start time<input type="time" value={startTime} onChange={(event)=>onStartTime(event.target.value)}/></label><label>End time<input type="time" value={endTime} onChange={(event)=>onEndTime(event.target.value)}/></label></div><label>Resource key<input value={resourceKey} onChange={(event)=>onResourceKey(event.target.value)}/></label><button disabled={!startTime || !endTime || !resourceKey || Boolean(actionBusy)} onClick={onProposeSchedule} type="button">{actionBusy === "schedule" ? "Submitting…" : "Propose Schedule Change"}</button></div>}
      {canRecommend && <><label>Recommendation notes<textarea maxLength={3000} value={internalNote} onChange={(event)=>onInternalNote(event.target.value)} rows={3}/></label><div className="staff-recommendation-reason"><label>Rejection reason (required for rejection)<textarea maxLength={3000} value={rejectionReason} onChange={(event)=>onRejectionReason(event.target.value)} rows={2}/></label></div><div className="staff-final-decision-note"><AlertTriangle size={15}/> Staff submissions are recommendations only. Final status changes are Admin/Owner-only.</div><div className="admin-inline-actions"><button disabled={!permission("recommend_approval") || Boolean(actionBusy)} onClick={()=>onRecommend("approve")} type="button">{actionBusy === "recommendation" ? "Submitting…" : "Recommend Approval"}</button><button disabled={!permission("recommend_rejection") || !rejectionReason.trim() || Boolean(actionBusy)} onClick={()=>onRecommend("reject")} type="button">{actionBusy === "recommendation" ? "Submitting…" : "Recommend Rejection"}</button></div></>}
      {!canRecommend && recommendationState === "awaiting_admin" && <p className="staff-final-decision-note"><Clock3 size={15}/> Recommendation submitted; awaiting Admin/Owner decision.</p>}
      {!canRecommend && recommendationState === "revision_requested" && recommendationStaff !== profileId && <p className="staff-final-decision-note"><AlertTriangle size={15}/> This recommendation was returned to its reviewer. Another staff member cannot revise it.</p>}
    </section>}
  </aside></div>;
}
