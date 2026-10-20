import { createBrowserClient } from "@supabase/ssr";
import type { SupabaseClient, User } from "@supabase/supabase-js";
import { projectId, publicAnonKey } from "../../utils/supabase/info";
import { fetchWithTimeout } from "./fetch-with-timeout";

const rememberPreferenceKey = "evently-auth-remember";
const oauthIntentKey = "evently-oauth-intent";
const configuredSupabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const configuredSupabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const supabaseUrl = configuredSupabaseUrl ?? `https://${projectId}.supabase.co`;
const supabaseAnonKey = configuredSupabaseAnonKey ?? publicAnonKey;
export const hasExplicitSupabaseConfiguration = Boolean(configuredSupabaseUrl && configuredSupabaseAnonKey);
const functionBaseUrl = `${supabaseUrl}/functions/v1/make-server-98c085dc`;
export const eventlyFunctionBaseUrl = functionBaseUrl;
export const eventlyOAuthCallback = "/auth/callback";

function requireSupabaseConfiguration() {
  if (!hasExplicitSupabaseConfiguration) {
    throw new Error("Supabase is not configured for this Next.js build. Set NEXT_PUBLIC_SUPABASE_URL and the current public anon/publishable key for the verified project, then rebuild.");
  }
}

export type AuthArea = "customer" | "admin" | "staff";
export type EventlyProfile = {
  avatar_url: string | null;
  id: string;
  email: string;
  full_name: string;
  username: string | null;
  mobile_number: string;
  staff_active?: boolean;
  role: "customer" | "owner" | "admin" | "staff";
};

export function describeSupabaseAuthError(error: unknown, fallback: string) {
  const message = error instanceof Error ? error.message : "";
  if (/invalid api key|invalidapikey/i.test(message)) {
    return "Supabase rejected the configured public API key. Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY from the same project as Jhoanna's profile.";
  }
  if (/abort|timeout|failed to fetch|network/i.test(message)) {
    return "Supabase could not be reached. Check the project URL, network connection, and try again.";
  }
  return message || fallback;
}

export function isMissingSupabaseRpc(error: { code?: string; message?: string } | null | undefined) {
  return Boolean(error && (
    error.code === "PGRST202"
    || error.code === "42883"
    || /could not find the function|function .* does not exist/i.test(error.message ?? "")
  ));
}

export async function markOwnEventlyNotificationsRead(ids: string[]) {
  const uniqueIds = [...new Set(ids.filter(Boolean))];
  if (!uniqueIds.length) return { error: null };

  const { data, error: sessionError } = await supabase.auth.getSession();
  if (sessionError) return { error: sessionError };
  const userId = data.session?.user.id;
  if (!userId) return { error: new Error("Sign in before updating notifications.") };

  const result = await supabase.rpc("mark_evently_notifications_read", { p_ids: uniqueIds });
  if (!result.error) return { error: null };
  if (!isMissingSupabaseRpc(result.error)) return { error: result.error };

  // Older deployed schemas may not yet have the notification RPC. This fallback
  // still goes through RLS and can only update the signed-in user's own rows.
  const fallback = await supabase.from("notifications")
    .update({ is_read: true })
    .eq("user_id", userId)
    .in("id", uniqueIds);
  return { error: fallback.error };
}

type RoleReadinessError = { code?: string; message?: string } | null;

export function staffRoleReadinessMessage(error: RoleReadinessError, ready: boolean | null) {
  if (error) {
    if (/invalid api key|invalidapikey/i.test(error.message ?? "")) {
      return "The configured Supabase public API key was rejected. Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY from the same project as this staff account.";
    }
    if (error.code === "42501" || /permission denied|row.level security|rls/i.test(error.message ?? "")) {
      return "Supabase denied the staff-role readiness check. Verify EXECUTE permission on evently_staff_role_ready() and the database role-check RLS setup.";
    }
    if (error.code === "PGRST202" || /function .*evently_staff_role_ready.*not found|could not find the function/i.test(error.message ?? "")) {
      return "The staff-role readiness migration is missing from the Supabase schema cache. Apply the staff-role migration and reload the API schema.";
    }
    if (/abort|timeout|fetch/i.test(error.message ?? "")) {
      return "Supabase could not be reached to verify staff access. Check the connection and try again.";
    }
    return `Supabase could not verify staff-role setup${error.message ? `: ${error.message}` : "."}`;
  }
  if (ready !== true) {
    return "Supabase reports that public.profiles.role does not yet accept staff. Apply the staff enum/check migration before provisioning staff accounts.";
  }
  return "";
}

export function staffPermissionsReadinessMessage(error: RoleReadinessError, ready: boolean | null) {
  if (error) {
    if (/invalid api key|invalidapikey/i.test(error.message ?? "")) {
      return "The configured Supabase public API key was rejected. Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY from the same project as this staff account.";
    }
    if (error.code === "42501" || /permission denied|row.level security|rls/i.test(error.message ?? "")) {
      return "Supabase denied the staff permissions readiness check. Verify EXECUTE permission and the staff permission RPC policies.";
    }
    if (error.code === "PGRST202" || /function .*evently_staff_permissions_ready.*not found|could not find the function/i.test(error.message ?? "")) {
      return "The staff permissions migration is not in the Supabase API schema. Apply the Staff Dashboard migration and reload the API schema.";
    }
    if (/abort|timeout|fetch/i.test(error.message ?? "")) {
      return "Supabase could not be reached to verify staff permissions. Check the connection and try again.";
    }
    return `Supabase could not verify staff permissions${error.message ? `: ${error.message}` : "."}`;
  }
  return ready === true
    ? ""
    : "The Staff Dashboard permission tables or required RPCs are missing. Apply the Staff Dashboard migration.";
}

const globalForSupabase = globalThis as typeof globalThis & {
  __eventlySupabase?: SupabaseClient;
};

export const supabase = globalForSupabase.__eventlySupabase ?? createBrowserClient(
  supabaseUrl,
  supabaseAnonKey,
  {
    auth: { autoRefreshToken: true, detectSessionInUrl: true, persistSession: true },
    global: { fetch: fetchWithTimeout },
  },
);

globalForSupabase.__eventlySupabase = supabase;

function setRememberPreference(remember: boolean) {
  if (remember) localStorage.setItem(rememberPreferenceKey, "true");
  else localStorage.removeItem(rememberPreferenceKey);
}

function getEventlyAuthRedirect(path: string) {
  return new URL(path, window.location.origin).toString();
}

async function resolveEmail(identifier: string) {
  if (identifier.includes("@")) return identifier;
  const response = await fetchWithTimeout(`${functionBaseUrl}/auth/resolve-username`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${supabaseAnonKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ username: identifier }),
  });
  const payload = await response.json();
  if (!response.ok || !payload.email) throw new Error(payload.error || "Account not found.");
  return payload.email as string;
}

export async function getEventlyProfile(user: User) {
  requireSupabaseConfiguration();
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 8_000);
  try {
    const result = await supabase.from("profiles")
      .select("id,email,full_name,username,mobile_number,avatar_url,role,staff_active")
      .eq("id", user.id).abortSignal(controller.signal).maybeSingle<EventlyProfile>();
    if (!result.error) return result.data;
    if (!/staff_active|column/i.test(result.error.message)) throw result.error;
    const fallback = await supabase.from("profiles")
      .select("id,email,full_name,username,mobile_number,avatar_url,role")
      .eq("id", user.id).abortSignal(controller.signal).maybeSingle<EventlyProfile>();
    if (fallback.error) throw fallback.error;
    return fallback.data ? { ...fallback.data, staff_active: true } : null;
  } finally {
    window.clearTimeout(timeout);
  }
}

export async function ensureCustomerProfile(user: User) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const existing = await getEventlyProfile(user);
      if (existing) return existing;
    } catch {
      // A profile read must never invalidate an authenticated Supabase session.
    }
    if (attempt < 2) await new Promise((resolve) => window.setTimeout(resolve, 150 * (attempt + 1)));
  }

  const metadata = user.user_metadata ?? {};
  return {
    avatar_url: metadata.avatar_url ?? metadata.picture ?? null,
    id: user.id,
    email: user.email ?? "",
    full_name: metadata.full_name ?? metadata.name ?? "",
    username: metadata.username || null,
    mobile_number: metadata.mobile_number ?? metadata.mobile ?? "",
    // Profile lookup failures must not grant an operations role from token metadata alone.
    role: "customer" as const,
  };
}

export async function signInCustomer(identifier: string, password: string, remember: boolean) {
  requireSupabaseConfiguration();
  setRememberPreference(remember);
  const email = await resolveEmail(identifier.trim());
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw new Error(describeSupabaseAuthError(error, "Unable to sign in."));
  return ensureCustomerProfile(data.user);
}

export async function signUpCustomer(profile: {
  fullName: string;
  username: string;
  email: string;
  mobile: string;
}, password: string) {
  requireSupabaseConfiguration();
  setRememberPreference(true);
  const { data, error } = await supabase.auth.signUp({
    email: profile.email,
    password,
    options: {
      data: {
        full_name: profile.fullName,
        username: profile.username,
        mobile_number: profile.mobile,
      },
    },
  });
  if (error) throw error;
  return data;
}

export async function signInAdmin(identifier: string, password: string, remember: boolean) {
  requireSupabaseConfiguration();
  setRememberPreference(remember);
  const email = await resolveEmail(identifier.trim());
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw new Error(describeSupabaseAuthError(error, "Unable to sign in."));
  const verified = await getVerifiedAdmin();
  if (!verified) {
    await supabase.auth.signOut();
    throw new Error("This account does not have owner or administrator access.");
  }
  return data.user;
}

export async function signInOperations(identifier: string, password: string, remember: boolean) {
  requireSupabaseConfiguration();
  setRememberPreference(remember);
  const email = await resolveEmail(identifier.trim());
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw new Error(describeSupabaseAuthError(error, "Unable to sign in."));
  let profile: EventlyProfile | null;
  try {
    profile = await getEventlyProfile(data.user);
  } catch (profileError) {
    await supabase.auth.signOut();
    const code = typeof profileError === "object" && profileError && "code" in profileError ? String(profileError.code) : "";
    const details = profileError instanceof Error ? profileError.message : "";
    if (/invalid api key|invalidapikey/i.test(details)) {
      throw new Error("The configured Supabase public API key was rejected. Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY from the same project as this staff account.");
    }
    if (code === "42501" || /permission denied|row.level security|rls/i.test(details)) {
      throw new Error("Supabase denied access to public.profiles. Verify the authenticated user's profile SELECT policy/RLS.");
    }
    if (/abort|timeout|fetch/i.test(details)) {
      throw new Error("The profile lookup timed out. Check Supabase connectivity and try signing in again.");
    }
    throw new Error("We could not verify your Evently profile. Check your connection and try signing in again.");
  }
  if (!profile) {
    const profileRole = await supabase.rpc("evently_current_profile_role");
    if (profileRole.error) {
      await supabase.auth.signOut();
      if (profileRole.error.code === "42501" || /permission denied|row.level security|rls/i.test(profileRole.error.message)) {
        throw new Error("Supabase denied the authenticated profile lookup. Verify the profiles SELECT RLS policy and EXECUTE permission on evently_current_profile_role().");
      }
      if (profileRole.error.code === "PGRST202" || /could not find the function/i.test(profileRole.error.message)) {
        throw new Error("The profile role diagnostic RPC is missing from Supabase. Apply the staff-role readiness migration and reload the API schema.");
      }
      throw new Error(describeSupabaseAuthError(profileRole.error, "The authenticated profile role could not be diagnosed."));
    }
    const storedRole = typeof profileRole.data === "string" ? profileRole.data : null;
    if (storedRole === "staff" || storedRole === "admin" || storedRole === "owner") {
      await supabase.auth.signOut();
      throw new Error(`public.profiles.role is '${storedRole}', but the profile SELECT query did not return the record. Verify the user's profiles SELECT RLS policy.`);
    }
    const roleReady = await supabase.rpc("evently_staff_role_ready");
    await supabase.auth.signOut();
    if (roleReady.error || roleReady.data !== true) throw new Error(staffRoleReadinessMessage(roleReady.error, roleReady.data));
    if (storedRole === "customer") {
      throw new Error("This account is a customer account (public.profiles.role='customer') and has not been provisioned for staff access.");
    }
    throw new Error(`No public.profiles row exists for authenticated user ${data.user.id}. Ask an administrator to provision the profile.`);
  }
  if (profile.role === "customer") {
    const roleReady = await supabase.rpc("evently_staff_role_ready");
    await supabase.auth.signOut();
    if (roleReady.error || roleReady.data !== true) throw new Error(staffRoleReadinessMessage(roleReady.error, roleReady.data));
    throw new Error(`This account is a customer account (public.profiles.role='${profile.role}') and has not been provisioned for staff access.`);
  }
  if (profile.role === "staff") {
    const roleReady = await supabase.rpc("evently_staff_role_ready");
    if (roleReady.error || roleReady.data !== true) {
      await supabase.auth.signOut();
      throw new Error(staffRoleReadinessMessage(roleReady.error, roleReady.data));
    }
    const permissionsReady = await supabase.rpc("evently_staff_permissions_ready");
    if (permissionsReady.error || permissionsReady.data !== true) {
      await supabase.auth.signOut();
      throw new Error(staffPermissionsReadinessMessage(permissionsReady.error, permissionsReady.data));
    }
    if (profile.staff_active === false) {
      await supabase.auth.signOut();
      throw new Error("Staff access for this account has been deactivated.");
    }
  }
  return profile;
}

export async function signInWithGoogle(area: AuthArea, returnTo: string) {
  requireSupabaseConfiguration();
  setRememberPreference(true);
  const fallback = area === "staff" ? "/staff/dashboard" : area === "admin" ? "/admin/dashboard" : "/";
  let safeReturnTo = fallback;
  try {
    const destination = new URL(returnTo, window.location.origin);
    const restrictedPath = /^\/(?:admin|staff|owner)(?:\/|$)/.test(destination.pathname);
    if (destination.origin === window.location.origin && !destination.pathname.startsWith("\\")
      && (area !== "customer" || !restrictedPath)) {
      safeReturnTo = `${destination.pathname}${destination.search}${destination.hash}`;
    }
  } catch {
    safeReturnTo = fallback;
  }
  if (area === "staff") safeReturnTo = "/staff/dashboard";
  if (area === "admin") safeReturnTo = "/admin/dashboard";
  sessionStorage.setItem(oauthIntentKey, JSON.stringify({ area, returnTo: safeReturnTo }));
  const callbackUrl = new URL(eventlyOAuthCallback, window.location.origin);
  callbackUrl.searchParams.set("next", safeReturnTo);
  const { error } = await supabase.auth.signInWithOAuth({
    provider: "google",
    options: {
      redirectTo: callbackUrl.toString(),
      queryParams: {
        access_type: "offline",
        prompt: "select_account",
      },
    },
  });
  if (error) throw error;
}

export async function completeOAuthSession() {
  const params = new URLSearchParams(window.location.search);
  const oauthError = params.get("error_description") || params.get("error");
  if (oauthError) throw new Error(oauthError.replace(/\+/g, " "));

  let { data, error } = await supabase.auth.getSession();
  if (error) throw error;

  const code = params.get("code");
  if (!data.session && code) {
    const exchanged = await supabase.auth.exchangeCodeForSession(code);
    if (exchanged.error) throw exchanged.error;
    data = exchanged.data;
  }
  if (!data.session) throw new Error("Google sign in completed, but no Evently session was returned.");
  return data.session;
}

export function consumeOAuthIntent(): { area: AuthArea; returnTo: string } {
  try {
    const intent = JSON.parse(sessionStorage.getItem(oauthIntentKey) ?? "");
    sessionStorage.removeItem(oauthIntentKey);
    if (intent.area === "admin" || intent.area === "staff" || intent.area === "customer") return intent;
  } catch {
    sessionStorage.removeItem(oauthIntentKey);
  }
  return { area: "customer", returnTo: "/" };
}

export async function getVerifiedAdmin() {
  const { data, error } = await supabase.auth.getSession();
  if (error || !data.session) return null;
  try {
    const profile = await getEventlyProfile(data.session.user);
    return profile?.role === "admin" || profile?.role === "owner" ? data.session.user : null;
  } catch {
    return null;
  }
}

export async function signOutUser() {
  localStorage.removeItem(rememberPreferenceKey);
  localStorage.removeItem("venice-customer-profile");
  sessionStorage.removeItem("evently-booking-draft");
  await supabase.auth.signOut();
}

export async function sendPasswordReset(email: string, area: AuthArea) {
  requireSupabaseConfiguration();
  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: getEventlyAuthRedirect(area === "admin" ? "/admin/login" : area === "staff" ? "/staff/login" : "/"),
  });
  if (error) throw error;
}

// Compatibility for modules retained by Vite HMR before the reset helper was generalized.
export function sendAdminPasswordReset(email: string) {
  return sendPasswordReset(email, "admin");
}
