import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import type { User } from "@supabase/supabase-js";
import { projectId, publicAnonKey } from "./utils/supabase/info";
import { fetchWithTimeout } from "./src/lib/fetch-with-timeout";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL ?? `https://${projectId}.supabase.co`;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? publicAnonKey;

export async function proxy(request: NextRequest) {
  const path = request.nextUrl.pathname;
  // Keep public auth entry points renderable even when the session/profile
  // service is slow; the browser client and submit handler have bounded fetches.
  if (path === "/staff/login" || path === "/admin/login" || path === "/auth/callback") {
    return NextResponse.next({ request });
  }

  let response = NextResponse.next({ request });
  const supabase = createServerClient(supabaseUrl, supabaseAnonKey, {
    global: { fetch: fetchWithTimeout },
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        cookiesToSet.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
      },
    },
  });

  // Refresh and validate the auth token at the server boundary. Database RLS
  // remains authoritative for all protected data and mutations.
  let user: User | null = null;
  try {
    const { data, error } = await supabase.auth.getUser();
    if (!error) user = data.user;
  } catch {
    // Fail closed for protected routes; public pages can still render during auth outages.
  }
  const isAdminArea = (path === "/admin" || path.startsWith("/admin/")) && path !== "/admin/login"
    || path === "/owner/dashboard";
  const isStaffArea = (path === "/staff" || path.startsWith("/staff/")) && path !== "/staff/login";
  const isCustomerArea = path === "/order" || path.startsWith("/account/");
  let redirectTo: string | null = null;

  if ((isAdminArea || isStaffArea || isCustomerArea) && !user) {
    redirectTo = isAdminArea ? "/admin/login" : isStaffArea ? "/staff/login" : "/";
  } else if (user && (isAdminArea || isStaffArea)) {
    const profileAbort = new AbortController();
    const profileTimeout = setTimeout(() => profileAbort.abort(), 8_000);
    let profile: { role: string; staff_active?: boolean } | null = null;
    let error: Error | null = null;
    try {
      const result = await supabase.from("profiles").select("role,staff_active")
        .eq("id", user.id).abortSignal(profileAbort.signal).maybeSingle();
      profile = result.data as { role: string; staff_active?: boolean } | null;
      error = result.error;
    } catch (profileError) {
      error = profileError instanceof Error ? profileError : new Error("Profile lookup failed");
    } finally {
      clearTimeout(profileTimeout);
    }
    if (error && /staff_active|column/i.test(error.message)) {
      const fallbackAbort = new AbortController();
      const fallbackTimeout = setTimeout(() => fallbackAbort.abort(), 8_000);
      try {
        const fallback = await supabase.from("profiles").select("role").eq("id", user.id)
          .abortSignal(fallbackAbort.signal).maybeSingle();
        profile = fallback.data ? { ...fallback.data, staff_active: true } as { role: string; staff_active?: boolean } : null;
        error = fallback.error;
      } catch (profileError) {
        error = profileError instanceof Error ? profileError : new Error("Profile lookup failed");
      } finally {
        clearTimeout(fallbackTimeout);
      }
    }
    if (isAdminArea && (error || (profile?.role !== "admin" && profile?.role !== "owner"))) {
      redirectTo = profile?.role === "staff" && profile.staff_active !== false ? "/staff/dashboard" : "/admin/login";
    }
    if (isStaffArea && (error || profile?.role !== "staff" || profile.staff_active === false)) {
      redirectTo = profile?.role === "admin" || profile?.role === "owner" ? "/admin/dashboard" : "/staff/login";
    }
    if (isStaffArea && !error && profile?.role === "staff" && profile.staff_active !== false) {
      const roleReadiness = await supabase.rpc("evently_staff_role_ready");
      if (roleReadiness.error) redirectTo = `/staff/login?oauth_error=${roleReadiness.error.code === "42501" ? "staff_role_check_denied" : roleReadiness.error.code === "PGRST202" ? "staff_role_check_unavailable" : "staff_role_check_failed"}`;
      else if (roleReadiness.data !== true) redirectTo = "/staff/login?oauth_error=staff_role_not_configured";
      else {
        const permissionReadiness = await supabase.rpc("evently_staff_permissions_ready");
        if (permissionReadiness.error) redirectTo = `/staff/login?oauth_error=${permissionReadiness.error.code === "42501" ? "staff_permissions_check_denied" : permissionReadiness.error.code === "PGRST202" ? "staff_permissions_check_unavailable" : "staff_permissions_check_failed"}`;
        else if (permissionReadiness.data !== true) redirectTo = "/staff/login?oauth_error=staff_permissions_not_configured";
      }
    }
  }

  if (redirectTo) {
    const redirectResponse = NextResponse.redirect(new URL(redirectTo, request.url));
    response.cookies.getAll().forEach((cookie) => redirectResponse.cookies.set(cookie));
    return redirectResponse;
  }
  return response;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|robots.txt|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)"],
};
