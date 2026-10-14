import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { projectId, publicAnonKey } from "../../utils/supabase/info";
import { fetchWithTimeout } from "./fetch-with-timeout";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL ?? `https://${projectId}.supabase.co`;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? publicAnonKey;

export async function createSupabaseServerClient() {
  const cookieStore = await cookies();

  return createServerClient(supabaseUrl, supabaseAnonKey, {
    global: { fetch: fetchWithTimeout },
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
        } catch {
          // Server Components can read cookies; Route Handlers and Server Actions can refresh them.
        }
      },
    },
  });
}
