import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseServerClient } from "../../../src/lib/supabase-server";

function safeLocalDestination(raw: string | null, origin: string) {
  if (!raw || !raw.startsWith("/") || raw.startsWith("//") || raw.includes("\\") || /[\r\n]/.test(raw)) return "/";
  try {
    const destination = new URL(raw, origin);
    if (destination.origin !== origin) return "/";
    return `${destination.pathname}${destination.search}${destination.hash}`;
  } catch {
    return "/";
  }
}

function redirectLocal(path: string, request: NextRequest) {
  const response = NextResponse.redirect(new URL(path, request.url));
  // Relative Location avoids redirecting to Next's internal 0.0.0.0 host in
  // containerized previews and still cannot leave the current origin.
  response.headers.set("Location", path);
  return response;
}

function requestedArea(next: string): "staff" | "admin" | "customer" {
  if (next === "/staff" || next.startsWith("/staff/")) return "staff";
  if (next === "/admin" || next.startsWith("/admin/") || next.startsWith("/owner/")) return "admin";
  return "customer";
}

function failureDestination(area: "staff" | "admin" | "customer", error: string) {
  if (area === "staff") return `/staff/login?oauth_error=${encodeURIComponent(error)}`;
  if (area === "admin") return `/admin/login?oauth_error=${encodeURIComponent(error)}`;
  return "/";
}

function supabaseFailureCode(error: { code?: string; message?: string } | null | undefined, fallback: string) {
  if (/invalid api key|invalidapikey/i.test(error?.message ?? "")) return "supabase_key_invalid";
  if (/invalid api key|invalidapikey/i.test(error?.message ?? "")) return "supabase_key_invalid";
  if (error?.code === "42501" || /permission denied|row.level security|rls/i.test(error?.message ?? "")) return "profile_permission_denied";
  return fallback;
}

export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const next = safeLocalDestination(url.searchParams.get("next"), url.origin);
  const area = requestedArea(next);
  const providerError = url.searchParams.get("error") || url.searchParams.get("error_description");
  if (providerError) return redirectLocal(failureDestination(area, "oauth_failed"), request);

  const code = url.searchParams.get("code");
  if (!code) return redirectLocal(failureDestination(area, "missing_code"), request);

  const supabase = await createSupabaseServerClient();
  const { error: exchangeError } = await supabase.auth.exchangeCodeForSession(code);
  if (exchangeError) return redirectLocal(failureDestination(area, supabaseFailureCode(exchangeError, "exchange_failed")), request);

  const { data: { user }, error: userError } = await supabase.auth.getUser();
  if (userError || !user) return redirectLocal(failureDestination(area, supabaseFailureCode(userError, "session_failed")), request);

  let { data: profile, error: profileError } = await supabase.from("profiles")
    .select("role,staff_active").eq("id", user.id).maybeSingle();
  if (profileError && /staff_active|column/i.test(profileError.message)) {
    const fallback = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
    profile = fallback.data ? { ...fallback.data, staff_active: true } : null;
    profileError = fallback.error;
  }
  if (profileError || !profile) {
    return redirectLocal(failureDestination(area, supabaseFailureCode(profileError, "profile_unavailable")), request);
  }

  if (profile.role === "staff") {
    const roleReadiness = await supabase.rpc("evently_staff_role_ready");
    if (roleReadiness.error) {
      const code = roleReadiness.error.code;
      const failure = code === "42501" ? "staff_role_check_denied"
        : code === "PGRST202" ? "staff_role_check_unavailable" : "staff_role_check_failed";
      return redirectLocal(failureDestination("staff", failure), request);
    }
    if (roleReadiness.data !== true) return redirectLocal(failureDestination("staff", "staff_role_not_configured"), request);
    const permissionReadiness = await supabase.rpc("evently_staff_permissions_ready");
    if (permissionReadiness.error) {
      const code = permissionReadiness.error.code;
      const failure = code === "42501" ? "staff_permissions_check_denied"
        : code === "PGRST202" ? "staff_permissions_check_unavailable" : "staff_permissions_check_failed";
      return redirectLocal(failureDestination("staff", failure), request);
    }
    if (permissionReadiness.data !== true) {
      return redirectLocal(failureDestination("staff", "staff_permissions_not_configured"), request);
    }
    if (profile.staff_active === false) {
      return redirectLocal(failureDestination("staff", "staff_inactive"), request);
    }
    return redirectLocal("/staff/dashboard", request);
  }

  if (profile.role === "admin" || profile.role === "owner") {
    return redirectLocal("/admin/dashboard", request);
  }

  if (profile.role !== "customer") {
    return redirectLocal(failureDestination(area, "role_unavailable"), request);
  }

  // Customer OAuth cannot use a staff/admin `next` path, even if a caller
  // supplied one in the URL.
  if (area === "staff" || area === "admin") {
    return redirectLocal(failureDestination(area, "role_required"), request);
  }
  return redirectLocal(next, request);
}
