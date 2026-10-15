"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type FormEvent,
  type ReactNode,
} from "react";
import { createPortal } from "react-dom";
import type { Session } from "@supabase/supabase-js";
import AdminDashboard from "./admin/AdminDashboard";
import {
  completeOAuthSession,
  consumeOAuthIntent,
  describeSupabaseAuthError,
  ensureCustomerProfile,
  eventlyFunctionBaseUrl,
  getEventlyProfile,
  getVerifiedAdmin,
  hasExplicitSupabaseConfiguration,
  sendPasswordReset,
  signInAdmin,
  signInOperations,
  signInCustomer,
  signInWithGoogle,
  signOutUser,
  signUpCustomer,
  staffPermissionsReadinessMessage,
  staffRoleReadinessMessage,
  supabase,
  type EventlyProfile,
} from "./lib/supabase";
import StaffPortal from "./staff/StaffPortal";
import { CustomerMessagesPanel, FloatingCustomerChat } from "./messaging/MessagingViews";

type AppLocation = {
  hash: string;
  pathname: string;
  search: string;
};

type NavigateOptions = {
  replace?: boolean;
};

type NavigationContextValue = {
  location: AppLocation;
  navigate: (to: string, options?: NavigateOptions) => void;
};

const NavigationContext = createContext<NavigationContextValue | null>(null);

type AuthContextValue = {
  loading: boolean;
  profile: EventlyProfile | null;
  profileError: string | null;
  session: Session | null;
};

const AuthContext = createContext<AuthContextValue | null>(null);

function useAuth() {
  const context = useContext(AuthContext);
  if (!context) throw new Error("Authentication context is unavailable.");
  return context;
}

function AuthProvider({ children }: { children: ReactNode }) {
  const [loading, setLoading] = useState(true);
  const [profile, setProfile] = useState<EventlyProfile | null>(null);
  const [profileError, setProfileError] = useState<string | null>(null);
  const [session, setSession] = useState<Session | null>(null);
  const activeUserId = useRef<string | null>(null);

  useEffect(() => {
    let mounted = true;
    let authEventVersion = 0;

    const synchronize = async (nextSession: Session | null) => {
      if (!mounted) return;
      const userId = nextSession?.user.id ?? null;
      if (activeUserId.current !== userId) {
        setLoading(true);
        setProfile(null);
      }
      activeUserId.current = userId;
      setSession(nextSession);

      if (!nextSession) {
        setProfile(null);
        setProfileError(null);
        setLoading(false);
        return;
      }

      const profileLoadTimeout = window.setTimeout(() => {
        if (mounted && activeUserId.current === userId) {
          setProfile(null);
          setLoading(false);
        }
      }, 8_500);
      let nextProfile: EventlyProfile | null = null;
      let nextProfileError: string | null = null;
      try {
        nextProfile = await getEventlyProfile(nextSession.user);
        if (!nextProfile) nextProfileError = "No profile row is visible for the authenticated account. Verify the profile exists and its RLS SELECT policy allows the user to read it.";
      } catch (error) {
        const code = typeof error === "object" && error && "code" in error ? String(error.code) : "";
        const detail = error instanceof Error ? error.message : "";
        nextProfileError = code === "42501" || /permission denied|row.level security|rls/i.test(detail)
          ? "Supabase denied access to the authenticated profile. Verify the profiles SELECT policy/RLS."
          : describeSupabaseAuthError(error, "The authenticated profile could not be verified.");
      } finally {
        window.clearTimeout(profileLoadTimeout);
      }
      if (!mounted || activeUserId.current !== userId) return;
      setProfile(nextProfile);
      setProfileError(nextProfileError);
      setLoading(false);
    };

    const { data: authListener } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      authEventVersion += 1;
      window.setTimeout(() => synchronize(nextSession), 0);
    });

    const sessionRequestVersion = authEventVersion;
    supabase.auth.getSession()
      .then(({ data, error }) => {
        if (authEventVersion === sessionRequestVersion) synchronize(error ? null : data.session);
      })
      .catch(() => {
        if (authEventVersion === sessionRequestVersion) synchronize(null);
      });

    return () => {
      mounted = false;
      authListener.subscription.unsubscribe();
    };
  }, []);

  return (
    <AuthContext.Provider value={{ loading, profile, profileError, session }}>
      {children}
    </AuthContext.Provider>
  );
}

function useNavigate() {
  const context = useContext(NavigationContext);
  if (!context) throw new Error("Navigation context is unavailable.");
  return context.navigate;
}

function useLocation() {
  const context = useContext(NavigationContext);
  if (!context) throw new Error("Navigation context is unavailable.");
  return context.location;
}

function Navigate({ replace = false, to }: { replace?: boolean; to: string }) {
  const navigate = useNavigate();
  useEffect(() => {
    navigate(to, { replace });
  }, [navigate, replace, to]);
  return null;
}

type IconName =
  | "arrow"
  | "bell"
  | "calendar"
  | "chevron"
  | "close"
  | "facebook"
  | "eye"
  | "eyeOff"
  | "instagram"
  | "menu"
  | "people"
  | "pin"
  | "sparkle"
  | "sun";

function Icon({ name, size = 20 }: { name: IconName; size?: number }) {
  const paths: Record<IconName, ReactNode> = {
    arrow: (
      <>
        <path d="M5 12h14" />
        <path d="m14 7 5 5-5 5" />
      </>
    ),
    bell: <path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4" />,
    calendar: (
      <>
        <rect x="3" y="5" width="18" height="16" rx="2" />
        <path d="M16 3v4M8 3v4M3 10h18" />
      </>
    ),
    chevron: <path d="m9 18 6-6-6-6" />,
    close: (
      <>
        <path d="m6 6 12 12" />
        <path d="m18 6-12 12" />
      </>
    ),
    facebook: <path d="M14 8h3V4h-3c-3 0-5 2-5 5v3H6v4h3v5h4v-5h3l1-4h-4V9c0-.7.3-1 1-1Z" />,
    eye: (
      <>
        <path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12Z" />
        <circle cx="12" cy="12" r="2.5" />
      </>
    ),
    eyeOff: (
      <>
        <path d="m3 3 18 18" />
        <path d="M10.6 6.2A9.4 9.4 0 0 1 12 6c6.5 0 10 6 10 6a17 17 0 0 1-2.1 2.8M6.2 6.2C3.5 8 2 12 2 12s3.5 6 10 6a9.8 9.8 0 0 0 3.8-.8" />
      </>
    ),
    instagram: (
      <>
        <rect x="3" y="3" width="18" height="18" rx="5" />
        <circle cx="12" cy="12" r="4" />
        <path d="M17.5 6.5h.01" />
      </>
    ),
    menu: (
      <>
        <path d="M4 7h16" />
        <path d="M4 12h16" />
        <path d="M4 17h16" />
      </>
    ),
    people: (
      <>
        <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" />
        <circle cx="9" cy="7" r="4" />
        <path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75" />
      </>
    ),
    pin: (
      <>
        <path d="M20 10c0 5-8 12-8 12S4 15 4 10a8 8 0 1 1 16 0Z" />
        <circle cx="12" cy="10" r="2.5" />
      </>
    ),
    sparkle: <path d="m12 2 1.7 6.3L20 10l-6.3 1.7L12 18l-1.7-6.3L4 10l6.3-1.7L12 2Z" />,
    sun: (
      <>
        <circle cx="12" cy="12" r="4" />
        <path d="M12 2v2M12 20v2M4.93 4.93l1.42 1.42M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.42-1.42M17.66 6.34l1.41-1.41" />
      </>
    ),
  };

  return (
    <svg
      aria-hidden="true"
      fill="none"
      height={size}
      viewBox="0 0 24 24"
      width={size}
      stroke="currentColor"
      strokeLinecap="round"
      strokeLinejoin="round"
      strokeWidth="1.8"
    >
      {paths[name]}
    </svg>
  );
}

function GoogleIcon() {
  return (
    <svg aria-hidden="true" height="18" viewBox="0 0 24 24" width="18">
      <path fill="#4285F4" d="M21.6 12.2c0-.7-.1-1.4-.2-2.1H12v4h5.4a4.6 4.6 0 0 1-2 3v2.6h3.3c1.9-1.8 2.9-4.4 2.9-7.5Z" />
      <path fill="#34A853" d="M12 22c2.7 0 5-.9 6.7-2.3l-3.3-2.6c-.9.6-2.1 1-3.4 1a5.9 5.9 0 0 1-5.5-4.1H3.1v2.7A10.1 10.1 0 0 0 12 22Z" />
      <path fill="#FBBC05" d="M6.5 14a6 6 0 0 1 0-3.9V7.4H3.1a10.1 10.1 0 0 0 0 9.3L6.5 14Z" />
      <path fill="#EA4335" d="M12 5.9c1.5 0 2.8.5 3.9 1.5l2.9-2.9A9.8 9.8 0 0 0 12 2a10.1 10.1 0 0 0-8.9 5.4l3.4 2.7A5.9 5.9 0 0 1 12 5.9Z" />
    </svg>
  );
}

const stockPhotos = {
  buffet: "https://images.unsplash.com/photo-1555244162-803834f70033?auto=format&fit=crop&w=1200&q=82",
  decorations: "https://images.unsplash.com/photo-1755704282977-340323fa52df?auto=format&fit=crop&w=1200&q=82",
  desserts: "https://images.unsplash.com/photo-1527751171053-6ac5ec50000b?auto=format&fit=crop&w=1200&q=82",
  eventDining: "https://images.unsplash.com/photo-1676734627786-a3662ff6a243?auto=format&fit=crop&w=1200&q=82",
  eventVenue: "https://images.unsplash.com/photo-1525441273400-056e9c7517b3?auto=format&fit=crop&w=1200&q=82",
  foodSpread: "https://images.unsplash.com/photo-1576842546422-60562b9242ae?auto=format&fit=crop&w=1200&q=82",
  outdoorDining: "https://images.unsplash.com/photo-1784450441823-fa8a7f017dc5?auto=format&fit=crop&w=1200&q=82",
  poolEvening: "https://images.unsplash.com/photo-1785910723802-99967d4fa265?auto=format&fit=crop&w=1200&q=82",
  resortGarden: "https://images.unsplash.com/photo-1760942992111-a65227a3b266?auto=format&fit=crop&w=1200&q=82",
  resortGrounds: "https://images.unsplash.com/photo-1776762893034-c437e452f1be?auto=format&fit=crop&w=1200&q=82",
  resortPool: "https://images.unsplash.com/photo-1596178060810-72f53ce9a65c?auto=format&fit=crop&w=1200&q=82",
  resortVilla: "https://images.unsplash.com/photo-1584132869994-873f9363a562?auto=format&fit=crop&w=1200&q=82",
} as const;

function photoForContext(context: string) {
  const normalized = context.toLowerCase();

  if (normalized.includes("decorations") || normalized.includes("setup")) {
    return { alt: "Elegant floral and balloon decorations prepared for a celebration", src: stockPhotos.decorations };
  }
  if (normalized.includes("pool & outdoor")) {
    return { alt: "Illuminated resort pool and outdoor lounge area", src: stockPhotos.poolEvening };
  }
  if (normalized.includes("food & catering")) {
    return { alt: "Professionally presented event buffet with assorted dishes", src: stockPhotos.foodSpread };
  }
  if (normalized.includes("events photo")) {
    return { alt: "Formal dining tables arranged for a memorable celebration", src: stockPhotos.eventDining };
  }
  if (normalized.includes("event + stay") || normalized.includes("resort + catering")) {
    return { alt: "Elegant outdoor dining setup in a tropical resort setting", src: stockPhotos.outdoorDining };
  }
  if (normalized.includes("event + catering") || normalized.includes("signature")) {
    return { alt: "Formal celebration tables arranged for an elegant catered event", src: stockPhotos.eventDining };
  }
  if (normalized.includes("catering") || normalized.includes("essential") || normalized.includes("gather")) {
    return { alt: "Catering buffet with a generous selection of prepared dishes", src: stockPhotos.buffet };
  }
  if (normalized.includes("dessert") || normalized.includes("final booking")) {
    return { alt: "Assorted desserts arranged for an event buffet", src: stockPhotos.desserts };
  }
  if (normalized.includes("event") || normalized.includes("venue") || normalized.includes("grand")) {
    return { alt: "Elegant flower-lined tables in a formal event venue", src: stockPhotos.eventVenue };
  }
  if (normalized.includes("overnight") || normalized.includes("escape")) {
    return { alt: "Private tropical resort villa with a relaxing pool area", src: stockPhotos.resortVilla };
  }
  if (normalized.includes("day tour") || normalized.includes("facilities")) {
    return { alt: "Tropical resort grounds with a swimming pool and lounge areas", src: stockPhotos.resortGrounds };
  }
  if (normalized.includes("pool")) {
    return { alt: "Clean tropical resort pool surrounded by greenery", src: stockPhotos.resortPool };
  }
  if (normalized.includes("resort")) {
    return { alt: "Private resort pool framed by tropical plants and a bamboo pavilion", src: stockPhotos.resortGarden };
  }
  if (normalized.includes("selected") || normalized.includes("reserved") || normalized.includes("reservation")) {
    return { alt: "Elegant catered table prepared for a private celebration", src: stockPhotos.eventDining };
  }
  return { alt: "Warm event dining setup prepared for a celebration", src: stockPhotos.eventDining };
}

function PhotoPlaceholder({
  context,
  className = "",
  compact = false,
}: {
  context: string;
  className?: string;
  compact?: boolean;
}) {
  const photo = photoForContext(context);

  return (
    <div className={`photo-placeholder ${compact ? "photo-placeholder--compact" : ""} ${className}`}>
      <img alt={photo.alt} decoding="async" loading="lazy" src={photo.src} />
    </div>
  );
}

function CustomerAvatarPlaceholder({ name }: { name: string }) {
  return (
    <span className="customer-photo-placeholder" aria-label={`${name} avatar placeholder`}>
      <Icon name="people" size={18} />
    </span>
  );
}

function Brand({ light = false }: { light?: boolean }) {
  return (
    <div className={`brand ${light ? "brand--light" : ""}`} aria-label="Venice">
      <span className="brand__name">VENICE</span>
      <span className="brand__line" />
      <span className="brand__sub">Catering · Events · Resort</span>
    </div>
  );
}

function EventlyBrand({ light = false, subtitle = "Events & Experiences" }: { light?: boolean; subtitle?: string }) {
  return (
    <div className={`admin-brand ${light ? "admin-brand--light" : ""}`} aria-label="Evently">
      <span className="admin-brand__mark"><Icon name="sparkle" size={18} /></span>
      <span>
        <strong>EVENTLY</strong>
        <small>{subtitle}</small>
      </span>
    </div>
  );
}

function Button({
  children,
  variant = "primary",
  href = "#inquire",
}: {
  children: ReactNode;
  variant?: "primary" | "booking" | "light" | "outline";
  href?: string;
}) {
  return (
    <a className={`button button--${variant}`} data-booking-cta={variant === "booking" ? "true" : undefined} href={href}>
      <span>{children}</span>
      <Icon name="arrow" size={18} />
    </a>
  );
}

function FloatingBookNow({ href }: { href: string }) {
  const [suppressed, setSuppressed] = useState(false);

  useEffect(() => {
    const visibleCtas = new Set<Element>();
    const observedCtas = new Set<Element>();
    let showTimer = 0;
    const rendered = (element: Element) => {
      if (!(element instanceof HTMLElement) || !element.isConnected) return false;
      if (element.matches(":disabled,[aria-disabled='true'],[hidden],[inert]")) return false;
      if (!element.getClientRects().length) return false;
      for (let parent: HTMLElement | null = element; parent; parent = parent.parentElement) {
        const style = window.getComputedStyle(parent);
        if (style.display === "none" || style.visibility === "hidden" || style.pointerEvents === "none" || Number(style.opacity) <= 0.02 || parent.getAttribute("aria-hidden") === "true" || parent.hasAttribute("inert")) return false;
      }
      return true;
    };
    const hasActiveBookingFlow = () => Array.from(document.querySelectorAll<HTMLElement>("[data-booking-flow-active='true']")).some((element) => {
      if (!element.isConnected || !element.getClientRects().length) return false;
      for (let parent: HTMLElement | null = element; parent; parent = parent.parentElement) {
        const style = window.getComputedStyle(parent);
        if (style.display === "none" || style.visibility === "hidden" || parent.getAttribute("aria-hidden") === "true" || parent.hasAttribute("inert")) return false;
      }
      return true;
    });
    const updateSuppression = () => {
      const shouldSuppress = hasActiveBookingFlow() || visibleCtas.size > 0;
      window.clearTimeout(showTimer);
      if (shouldSuppress) setSuppressed(true);
      else showTimer = window.setTimeout(() => setSuppressed(false), 120);
    };
    const ctaObserver = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        const target = entry.target;
        if (entry.isIntersecting && rendered(target)) visibleCtas.add(target);
        else visibleCtas.delete(target);
      });
      updateSuppression();
    }, { root: null, rootMargin: "-8px 0px -8px 0px", threshold: 0.01 });
    const reconcileCtas = () => {
      const current = new Set(document.querySelectorAll("[data-booking-cta='true']:not(.floating-book-now)"));
      observedCtas.forEach((element) => {
        if (!current.has(element)) {
          ctaObserver.unobserve(element);
          observedCtas.delete(element);
          visibleCtas.delete(element);
        }
      });
      current.forEach((element) => {
        if (!observedCtas.has(element)) {
          observedCtas.add(element);
          ctaObserver.observe(element);
        }
      });
      updateSuppression();
    };
    const mutations = new MutationObserver(() => {
      reconcileCtas();
      observedCtas.forEach((element) => {
        ctaObserver.unobserve(element);
        ctaObserver.observe(element);
      });
    });
    reconcileCtas();
    mutations.observe(document.body, {
      attributes: true,
      attributeFilter: ["aria-disabled", "aria-hidden", "class", "data-booking-cta", "data-booking-flow-active", "disabled", "hidden", "inert", "style"],
      childList: true,
      subtree: true,
    });
    return () => {
      window.clearTimeout(showTimer);
      mutations.disconnect();
      ctaObserver.disconnect();
    };
  }, []);

  return (
    <a aria-hidden={suppressed} className={`floating-book-now ${suppressed ? "floating-book-now--hidden" : ""}`} href={href} inert={suppressed} tabIndex={suppressed ? -1 : 0} aria-label="Book Now">
      <span className="floating-book-now__icon"><Icon name="calendar" size={19} /></span>
      <strong>Book Now</strong>
      <Icon name="arrow" size={19} />
    </a>
  );
}

type AsyncState = "default" | "loading" | "success" | "error";

function StatefulButton({
  label,
  loadingLabel = "Please wait...",
  state = "default",
  className = "",
  type = "button",
  onClick,
  disabled = false,
}: {
  label: string;
  loadingLabel?: string;
  state?: AsyncState;
  className?: string;
  type?: "button" | "submit";
  onClick?: () => void;
  disabled?: boolean;
}) {
  return (
    <button
      className={`stateful-button stateful-button--${state} ${className}`}
      disabled={disabled || state === "loading" || state === "success"}
      onClick={onClick}
      type={type}
    >
      {state === "loading" && <span className="button-spinner" />}
      {state === "success" && <span>✓</span>}
      {state === "error" && <span>!</span>}
      <span>{state === "loading" ? loadingLabel : label}</span>
      {state === "default" && <Icon name="arrow" size={17} />}
    </button>
  );
}

function FeedbackToast({
  message,
  type = "success",
  onClose,
}: {
  message: string;
  type?: "success" | "error";
  onClose: () => void;
}) {
  useEffect(() => {
    const timeout = window.setTimeout(onClose, 3200);
    return () => window.clearTimeout(timeout);
  }, [onClose]);

  return (
    <div className={`feedback-toast feedback-toast--${type}`} role="status">
      <span>{type === "success" ? "✓" : "!"}</span>
      <strong>{message}</strong>
      <button aria-label="Dismiss notification" onClick={onClose} type="button"><Icon name="close" size={15} /></button>
    </div>
  );
}

function AnimatedRating({ rating }: { rating: number }) {
  const ratingRef = useRef<HTMLDivElement>(null);
  const hasStarted = useRef(false);
  const timeouts = useRef<number[]>([]);
  const [visibleStars, setVisibleStars] = useState(0);
  const [completed, setCompleted] = useState(false);

  useEffect(() => {
    const element = ratingRef.current;
    if (!element) return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (!entries[0]?.isIntersecting || hasStarted.current) return;
        hasStarted.current = true;
        observer.disconnect();
        for (let star = 1; star <= rating; star += 1) {
          const timeout = window.setTimeout(() => {
            setVisibleStars(star);
            if (star === rating) setCompleted(true);
          }, 120 + star * 130);
          timeouts.current.push(timeout);
        }
      },
      { threshold: 0.25 },
    );
    observer.observe(element);
    return () => {
      observer.disconnect();
      timeouts.current.forEach((timeout) => window.clearTimeout(timeout));
    };
  }, [rating]);

  return (
    <div
      className={`review-card__stars review-rating ${completed ? "review-rating--complete" : ""}`}
      aria-label={`${rating} out of 5 stars`}
      ref={ratingRef}
    >
      {Array.from({ length: 5 }, (_, starIndex) => {
        const filled = starIndex < visibleStars;
        return (
          <span className={`review-star ${filled ? "review-star--filled" : "review-star--empty"}`} key={starIndex}>
            {filled ? "★" : "☆"}
          </span>
        );
      })}
    </div>
  );
}

type CustomerAccountProfile = {
  fullName: string;
  username: string;
  email: string;
  mobile: string;
  smsNotifications: boolean;
  accountCreated: string;
};

function toCustomerAccountProfile(profile: {
  full_name?: string;
  username?: string | null;
  email?: string;
  mobile_number?: string;
}): CustomerAccountProfile {
  return {
    fullName: profile.full_name || "Evently Customer",
    username: profile.username || "",
    email: profile.email || "",
    mobile: profile.mobile_number || "",
    smsNotifications: true,
    accountCreated: new Date().toISOString(),
  };
}

function normalizePhilippineMobile(value: string) {
  if (!/^09\d{9}$/.test(value)) return null;
  return value;
}

function normalizedService(value: string) {
  const normalized = value.trim().toLowerCase().replace(/[&_/-]+/g, " ").replace(/\s+/g, " ");
  if (/food|party tray|tray/.test(normalized)) return "food";
  if (/event|venue/.test(normalized)) return "event";
  if (/staycation|swim|pool|resort|room|accommodation/.test(normalized)) return "resort";
  if (/cater/.test(normalized)) return "catering";
  return normalized;
}

function readCustomerProfile(): CustomerAccountProfile | null {
  try {
    return JSON.parse(localStorage.getItem("venice-customer-profile") ?? "null");
  } catch {
    return null;
  }
}

function BookingLoginModal({
  onClose,
  onContinue,
  purpose = "booking",
}: {
  onClose: () => void;
  onContinue: (mode: "login" | "account", profile?: CustomerAccountProfile) => void;
  purpose?: "booking" | "account";
}) {
  const navigate = useNavigate();
  const [email, setEmail] = useState("");
  const [fullName, setFullName] = useState("");
  const [username, setUsername] = useState("");
  const [mobile, setMobile] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [remember, setRemember] = useState(true);
  const [mode, setMode] = useState<"login" | "account">("login");
  const [loginState, setLoginState] = useState<AsyncState>("default");
  const [googleState, setGoogleState] = useState<AsyncState>("default");
  const [registrationError, setRegistrationError] = useState("");

  useEffect(() => {
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = "";
    };
  }, []);

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setRegistrationError("");
    if (mode === "account") {
      const normalizedMobile = normalizePhilippineMobile(mobile);
      if (!fullName.trim() || !username.trim() || !email.trim() || !password) {
        setRegistrationError("Complete all required fields to create your account.");
        setLoginState("error");
        return;
      }
      if (!normalizedMobile) {
        setRegistrationError("Enter a valid Philippine mobile number, such as 0917 123 4567.");
        setLoginState("error");
        return;
      }
      if (password.length < 8) {
        setRegistrationError("Your password must contain at least 8 characters.");
        setLoginState("error");
        return;
      }
      if (password !== confirmPassword) {
        setRegistrationError("Passwords do not match.");
        setLoginState("error");
        return;
      }
      const profile: CustomerAccountProfile = {
        fullName: fullName.trim(),
        username: username.trim(),
        email: email.trim(),
        mobile: normalizedMobile,
        smsNotifications: true,
        accountCreated: new Date().toISOString(),
      };
      setLoginState("loading");
      try {
        const { user, session } = await signUpCustomer(profile, password);
        if (!session) {
          setLoginState("default");
          setRegistrationError(
            user
              ? "Account created successfully. Please check your email to confirm your account, then sign in."
              : "Unable to create your account. Please try again.",
          );
          return;
        }
        const eventlyProfile = await ensureCustomerProfile(session.user);
        const customerProfile = toCustomerAccountProfile(eventlyProfile);
        localStorage.setItem("venice-customer-profile", JSON.stringify(customerProfile));
        setLoginState("success");
        onContinue("account", customerProfile);
      } catch (error) {
        setLoginState("error");
        setRegistrationError(error instanceof Error ? error.message : "Unable to create your account.");
      }
      return;
    }
    if (!email.trim() || !password.trim()) {
      setLoginState("error");
      return;
    }
    setLoginState("loading");
    try {
      const profile = await signInCustomer(email, password, remember);
      if (profile.role === "staff") { navigate("/staff/dashboard", { replace: true }); return; }
      if (profile.role === "admin" || profile.role === "owner") { navigate("/admin/dashboard", { replace: true }); return; }
      const customerProfile = profile ? toCustomerAccountProfile(profile) : undefined;
      if (customerProfile) localStorage.setItem("venice-customer-profile", JSON.stringify(customerProfile));
      setLoginState("success");
      onContinue("login", customerProfile);
    } catch (error) {
      setLoginState("error");
      setRegistrationError(error instanceof Error ? error.message : "Unable to sign in.");
    }
  };

  const continueWithGoogle = async () => {
    setGoogleState("loading");
    setRegistrationError("");
    try {
      const returnTo = `${window.location.pathname}${window.location.search}#booking`;
      await signInWithGoogle("customer", returnTo);
    } catch (error) {
      setGoogleState("error");
      setRegistrationError(error instanceof Error ? error.message : "Unable to start Google sign in.");
    }
  };

  const forgotPassword = async () => {
    if (!email.includes("@")) {
      setLoginState("error");
      setRegistrationError("Enter your account email to request a password reset.");
      return;
    }
    try {
      await sendPasswordReset(email.trim(), "customer");
      setRegistrationError("Password reset instructions have been sent to your email.");
    } catch (error) {
      setLoginState("error");
      setRegistrationError(error instanceof Error ? error.message : "Unable to send reset instructions.");
    }
  };

  return createPortal(
    <div className="booking-login-wrap" data-booking-flow-active="true" role="presentation">
      <button className="booking-login__backdrop" aria-label="Close booking login" onClick={onClose} type="button" />
      <section className="booking-login-modal" role="dialog" aria-modal="true" aria-labelledby="booking-login-title">
        <button className="booking-login__close" aria-label="Close booking login" onClick={onClose} type="button"><Icon name="close" /></button>
        <EventlyBrand />
        <span className="section-kicker">{mode === "login" ? purpose === "booking" ? "Finalize your reservation" : "Customer account" : "Join Venice"}</span>
        <h2 id="booking-login-title">{mode === "login" ? "Welcome Back" : "Create Your Account"}</h2>
        <p>{mode === "login" ? purpose === "booking" ? "Sign in to finalize and submit your reservation." : "Sign in to access your Evently account." : purpose === "booking" ? "Create an account to finalize and submit your reservation." : "Create your Evently customer account."}</p>
        <small className="booking-login__preserve">Your current booking selections will be preserved.</small>
        <form className={mode === "account" ? "booking-registration-form" : ""} onSubmit={submit}>
          {mode === "account" && (
            <>
              <label><span>Full Name</span><input autoComplete="name" onChange={(event) => { setFullName(event.target.value); setRegistrationError(""); }} placeholder="Your full name" required type="text" value={fullName} /></label>
              <label><span>Username</span><input autoComplete="username" onChange={(event) => { setUsername(event.target.value); setRegistrationError(""); }} placeholder="Choose a username" required type="text" value={username} /></label>
            </>
          )}
          <label><span>{mode === "login" ? "Username or Email" : "Email Address"}</span><input autoComplete="email" onChange={(event) => { setEmail(event.target.value); setLoginState("default"); setRegistrationError(""); }} placeholder={mode === "login" ? "Enter your username or email" : "you@example.com"} required type={mode === "login" ? "text" : "email"} value={email} /></label>
          {mode === "account" && (
            <label>
              <span>Mobile Number</span>
              <input
                autoComplete="tel"
                inputMode="tel"
                onBlur={() => {
                  const normalized = normalizePhilippineMobile(mobile);
                  if (normalized) setMobile(normalized);
                }}
                onChange={(event) => { setMobile(event.target.value); setRegistrationError(""); }}
                placeholder="09XX XXX XXXX"
                required
                type="tel"
                value={mobile}
              />
              <small>Your mobile number will be used for booking updates and important notifications.</small>
            </label>
          )}
          <label>
            <span>Password</span>
            <div className="booking-password-field">
              <input autoComplete={mode === "login" ? "current-password" : "new-password"} onChange={(event) => { setPassword(event.target.value); setLoginState("default"); }} placeholder="Enter your password" type={showPassword ? "text" : "password"} value={password} />
              <button aria-label={showPassword ? "Hide password" : "Show password"} onClick={() => setShowPassword((visible) => !visible)} type="button"><Icon name={showPassword ? "eyeOff" : "eye"} size={18} /></button>
            </div>
          </label>
          {mode === "account" && (
            <label>
              <span>Confirm Password</span>
              <input autoComplete="new-password" onChange={(event) => { setConfirmPassword(event.target.value); setRegistrationError(""); }} placeholder="Confirm your password" required type="password" value={confirmPassword} />
            </label>
          )}
          {mode === "login" && (
            <div className="booking-login__options">
              <label><input checked={remember} onChange={(event) => setRemember(event.target.checked)} type="checkbox" /><span>Remember me</span></label>
              <button onClick={forgotPassword} type="button">Forgot password?</button>
            </div>
          )}
          <StatefulButton
            className="booking-login__submit"
            label={loginState === "success" ? mode === "login" ? "Signed In" : "Account Created" : mode === "login" ? "Sign In" : "Create Account"}
            loadingLabel={mode === "login" ? "Signing in..." : "Creating account..."}
            state={loginState}
            type="submit"
          />
          {(loginState === "error" || registrationError) && <span className="booking-login__error" role="status">{registrationError || "Enter your username or email and password to continue."}</span>}
        </form>
        <div className="booking-login__divider"><span>OR</span></div>
        <button className="booking-login__google" disabled={googleState === "loading"} onClick={continueWithGoogle} type="button">
          {googleState === "loading" ? <span className="button-spinner button-spinner--dark" /> : <GoogleIcon />}
          <span>{googleState === "loading" ? "Connecting..." : "Continue with Google"}</span>
        </button>
        <p className="booking-login__switch">
          {mode === "login" ? "New to Evently?" : "Already have an account?"}
          <button onClick={() => { setMode((current) => current === "login" ? "account" : "login"); setLoginState("default"); }} type="button">
            {mode === "login" ? "Create an Account" : "Login"}
          </button>
        </p>
      </section>
    </div>,
    document.body,
  );
}

function PalmAccent({ className = "" }: { className?: string }) {
  return (
    <svg className={`palm-accent ${className}`} viewBox="0 0 180 240" aria-hidden="true">
      <path d="M28 236C45 166 75 100 137 28" />
      <path d="M99 74c-40-8-62 3-82 22 36 8 61-1 82-22Z" />
      <path d="M117 51c-13-29-33-41-58-46 12 31 31 44 58 46Z" />
      <path d="M77 104c-38 0-61 14-77 37 36 2 60-10 77-37Z" />
      <path d="M128 39c14-25 34-36 52-39-11 28-28 40-52 39Z" />
      <path d="M105 66c29-17 53-17 75-8-25 20-49 23-75 8Z" />
    </svg>
  );
}

type AvailabilityStatus = "available" | "reserved" | "unavailable";

type VenicePackage = {
  name: string;
  detail: string;
  inclusions: string[];
  price: number;
  priceLabel?: string;
  popular?: boolean;
};

type VeniceService = {
  id: string;
  label: string;
  description: string;
  imageContext: string;
  packages: VenicePackage[];
  extras: { name: string; price: number; description?: string; imageContext?: string }[];
  quantityMode?: "items" | "tour" | "rooms";
};

const serviceCatalog: VeniceService[] = [
  {
    id: "Catering",
    label: "Catering Services",
    description: "Complete buffet service for intimate gatherings and grand celebrations.",
    imageContext: "Food & Catering Photo",
    packages: [
      { name: "Basic Catering", detail: "Six-dish curated buffet", inclusions: ["6 dishes", "Rice", "Dessert", "Drinks"], price: 28000 },
      { name: "Standard Catering", detail: "Six-dish buffet with elevated service", inclusions: ["6 dishes", "Rice", "Dessert", "Drinks"], price: 38000, popular: true },
      { name: "Premium Catering", detail: "Six-dish premium celebration buffet", inclusions: ["6 dishes", "Rice", "Dessert", "Drinks"], price: 52000 },
    ],
    extras: [
      { name: "Wedding Backdrop", price: 5000, description: "An elegant focal point styled for your ceremony or reception.", imageContext: "Wedding Decorations & Setups Photo" },
      { name: "Themed Backdrop", price: 3000, description: "A coordinated backdrop designed around your celebration theme.", imageContext: "Themed Event Decorations Photo" },
      { name: "2-Layer Cake", price: 3500, description: "A celebration cake finished to complement your event.", imageContext: "Celebration Cake Photo" },
      { name: "Host", price: 2500, description: "A professional host to keep your program warm and organized.", imageContext: "Event Host Photo" },
      { name: "2 Clowns", price: 2000, description: "Lively family entertainment for children and guests.", imageContext: "Children Party Entertainment Photo" },
      { name: "Grazing", price: 7000, description: "A generous grazing spread for guests to enjoy throughout the event.", imageContext: "Grazing Table Food Photo" },
      { name: "Sound System", price: 4000, description: "Clear event audio for music, announcements, and the program.", imageContext: "Event Sound System Photo" },
      { name: "Sound System with Lights", price: 5000, description: "Complete event audio with coordinated ambient lighting.", imageContext: "Event Lights and Sound Photo" },
    ],
  },
  {
    id: "Food Orders & Party Trays",
    label: "Food Orders & Party Trays",
    description: "Ready-to-share Venice favorites for pickup or delivery.",
    imageContext: "Party Trays Food Photo",
    quantityMode: "items",
    packages: [
      { name: "Spaghetti Party Tray", detail: "Solo Party Trays", inclusions: ["Good for sharing"], price: 1450 },
      { name: "Carbonara Party Tray", detail: "Solo Party Trays", inclusions: ["Good for sharing"], price: 1650 },
      { name: "Pancit Bihon Party Tray", detail: "Solo Party Trays", inclusions: ["Good for sharing"], price: 1350 },
      { name: "Baked Mac Party Tray", detail: "Solo Party Trays", inclusions: ["Good for sharing"], price: 1750 },
      { name: "Spaghetti + Fried Chicken", detail: "Duo Party Trays", inclusions: ["Two crowd favorites"], price: 2850, popular: true },
      { name: "Pancit + Lumpia", detail: "Duo Party Trays", inclusions: ["A classic merienda pair"], price: 2450 },
    ],
    extras: [
      { name: "Extra rice tray", price: 650 },
      { name: "Disposable dining set", price: 350 },
    ],
  },
  {
    id: "Event",
    label: "Events & Venue",
    description: "Flexible spaces and hands-on support for every milestone.",
    imageContext: "Event & Venue Photo",
    packages: [
      { name: "Basic Venue Rental", detail: "Venue access for your own event plan", inclusions: ["Tables", "Chairs"], price: 35000 },
      { name: "Standard Venue Package", detail: "A polished venue setup", inclusions: ["Tables", "Chairs", "Basic styling", "Sound system"], price: 55000, popular: true },
      { name: "Premium Event Package", detail: "Complete premium event support", inclusions: ["Venue", "Full styling", "Lights", "Sound system", "Event coordinator"], price: 85000 },
    ],
    extras: [
      { name: "Photo booth", price: 4500 },
      { name: "Extended venue hour", price: 5000 },
      { name: "Mobile bar setup", price: 6500 },
    ],
  },
  {
    id: "Swimming Pool",
    label: "Staycation & Swimming",
    description: "Choose a fixed day, night, or overnight pool tour.",
    imageContext: "Pool & Resort Facilities Photo",
    quantityMode: "tour",
    packages: [
      { name: "Day Tour", detail: "8:00 AM – 3:00 PM", inclusions: ["₱100 per guest", "Optional cottage ₱700"], price: 100, priceLabel: "₱100 / guest" },
      { name: "Night Tour", detail: "4:00 PM – 10:00 PM", inclusions: ["₱150 per guest", "Optional cottage ₱700"], price: 150, priceLabel: "₱150 / guest" },
      { name: "Overnight Tour", detail: "7:00 PM – 4:00 AM the following day", inclusions: ["₱200 per guest", "Minimum 20 guests", "Optional cottage ₱1,000"], price: 200, priceLabel: "₱200 / guest" },
    ],
    extras: [],
  },
  {
    id: "Room Accommodation",
    label: "Room Accommodation",
    description: "Comfortable rooms for guests who want to stay close.",
    imageContext: "Resort Room Accommodation Photo",
    packages: [
      { name: "Standard Room", detail: "For 4–5 guests", inclusions: ["Configured check-in and checkout required"], price: 3000, priceLabel: "₱3,000" },
      { name: "Kubo Room", detail: "Capacity pending business confirmation", inclusions: ["Configured check-in and checkout required"], price: 1500, priceLabel: "₱1,500" },
    ],
    extras: [
      { name: "Extra mattress", price: 800 },
      { name: "Breakfast per room", price: 1200 },
    ],
  },
];

const serviceById = (id: string) => serviceCatalog.find((item) => item.id === id);
const serviceLabel = (id: string) => serviceById(id)?.label ?? id;
const roomPackageNames = new Set(["standard room", "kubo room"]);
const swimmingPackageNames = new Set(["day tour", "day tour admission", "resort day tour", "night tour", "night tour admission", "resort night tour", "overnight tour", "overnight resort stay", "resort overnight tour"]);
type ScheduleMode = "untimed" | "fixed" | "customer_select" | "admin_assign";
const serviceScheduleDefaults: Record<string, { mode: ScheduleMode; start?: string; end?: string; durationMinutes?: number }> = {
  Catering: { mode: "customer_select", durationMinutes: 240 },
  "Swimming Pool": { mode: "fixed" },
  "Room Accommodation": { mode: "admin_assign" },
};
const timeMinutes = (value: string) => {
  const [hours, minutes] = value.slice(0, 5).split(":").map(Number);
  return Number.isFinite(hours) && Number.isFinite(minutes) ? hours * 60 + minutes : null;
};
const scheduleDuration = (start: string, end: string) => {
  const startMinutes = timeMinutes(start);
  const endMinutes = timeMinutes(end);
  if (startMinutes === null || endMinutes === null || startMinutes === endMinutes) return 0;
  return endMinutes > startMinutes ? endMinutes - startMinutes : 1440 - startMinutes + endMinutes;
};
const addScheduleMinutes = (start: string, duration: number) => {
  const startMinutes = timeMinutes(start);
  if (startMinutes === null) return "";
  const total = (startMinutes + duration) % 1440;
  return `${String(Math.floor(total / 60)).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
};
const scheduleWithinWindow = (start: string, end: string, operatingStart: string, operatingEnd: string) => {
  const startValue = timeMinutes(start);
  const endValue = timeMinutes(end);
  const windowStart = timeMinutes(operatingStart);
  const windowEnd = timeMinutes(operatingEnd);
  if (startValue === null || endValue === null || windowStart === null || windowEnd === null) return false;
  const normalizedEnd = endValue <= startValue ? endValue + 1440 : endValue;
  const normalizedWindowEnd = windowEnd <= windowStart ? windowEnd + 1440 : windowEnd;
  return startValue >= windowStart && normalizedEnd <= normalizedWindowEnd;
};
const compatibleAddOnsFor = (serviceId: string, packageName: string) => {
  const service = serviceById(serviceId);
  const selectedPackage = service?.packages.find((item) => item.name === packageName);
  const included = (selectedPackage?.inclusions ?? []).map((item) => item.toLowerCase());
  return (service?.extras ?? []).filter((extra) => {
    const addOnName = extra.name.toLowerCase();
    return !included.some((item) => addOnName.includes(item) || item.includes(addOnName));
  });
};
const formatPhp = (value: number) =>
  new Intl.NumberFormat("en-PH", {
    style: "currency",
    currency: "PHP",
    maximumFractionDigits: 2,
  }).format(value);

const normalizeDepositPercentage = (value: unknown) => {
  const percentage = Number(value);
  return Number.isFinite(percentage) ? Math.min(100, Math.max(0, percentage)) : 0;
};

const calculateRequiredDeposit = (totalAmount: number, percentage: unknown) =>
  Math.round(Math.max(0, totalAmount) * normalizeDepositPercentage(percentage)) / 100;

const cateringMenu = [
  { key: "Beef", items: ["Mushroom", "Broccoli", "Steak", "Caldereta"] },
  { key: "Pork", items: ["Caldereta", "Dinakdakan", "Sweet & Sour", "Grilled Liempo", "Asado", "Humba"] },
  { key: "Chicken", items: ["Cordon Bleu", "Chicken Inasal", "Chicken Teriyaki", "Butter Garlic Chicken", "Lemon Chicken", "Spicy Wings"] },
  { key: "Seafood", items: ["Fish Fillet", "Shrimp Tempura", "Buttered Shrimp", "Sweet & Sour Fish"] },
  { key: "Vegetable", items: ["Chopsuey", "Lumpiang Ubod", "Buttered Vegetable", "Vegetable Salad", "Fried Vegetable Lumpia"] },
  { key: "Pasta / Pancit", items: ["Mixed Pancit", "Mixed Sotanghon", "Palabok", "Carbonara", "Spaghetti", "Shanghai Rolls"] },
  { key: "Dessert", items: ["Fruit Salad", "Coffee Jelly", "Mango Tapioca", "Buko Pandan", "Buko Salad"] },
  { key: "Drinks", items: ["Iced Tea", "Cucumber Lemon", "Four Seasons", "Pineapple"] },
] as const;

const normalizeMenuCategory = (value: unknown) => {
  const normalized = String(value ?? "").trim().toLowerCase().replace(/\s+/g, " ");
  if (["pancit", "pansit", "pasta", "pasta/pancit", "pasta / pancit", "pasta and pancit"].includes(normalized)) return "pasta / pancit";
  return normalized;
};

const requiredMenuCategories = cateringMenu.map(({ key }) => key);

// Keep derived legacy bindings during Fast Refresh so a component retained from
// an earlier module version cannot crash while Vite swaps in the new catalog.
const reservationServices = serviceCatalog.map(({ id, description }) => [id, description] as const);
const serviceBasePrices = Object.fromEntries(
  serviceCatalog.map(({ id, packages }) => [id, packages.find(({ price }) => price > 0)?.price ?? 0]),
) as Record<string, number>;
const packageTiers = [
  { name: "Essential", detail: "A simple Venice experience", multiplier: 1 },
  { name: "Signature", detail: "Our most popular Venice experience", multiplier: 1.35 },
  { name: "Grand", detail: "A complete Venice experience", multiplier: 1.75 },
];
const addOnOptions = serviceCatalog.flatMap(({ extras }) => extras).filter(
  (extra, index, all) => all.findIndex(({ name }) => name === extra.name) === index,
);

const bookingDraftKey = "evently-booking-draft";
const customerBookingsChangedEvent = "evently-customer-bookings-changed";

type BookingDraft = {
  clientRequestId: string;
  step: number;
  service: string;
  selectedDate: string | null;
  month: string;
  selectedPackageId: string;
  selectedVariantId: string;
  selectedPackage?: string;
  guests: number;
  guestName: string;
  email: string;
  phone: string;
  addOns: string[];
  itemQuantity: number;
  adults: number;
  children: number;
  rooms: number;
  nights: number;
  cottageSelected: boolean;
  poolAccessSelected: boolean;
  specialRequests: string;
  startTime: string;
  endTime: string;
  menuSelections: Record<string, string>;
  paymentMethod?: CustomerPaymentMethod;
  paymentAmount?: string;
  paymentReference?: string;
};

type BookingPackageRow = {
  category?: string | null;
  deposit_percentage: number | null;
  description: string;
  guest_capacity: number | null;
  id: string;
  menu_items: string[] | null;
  name: string;
  price: number;
  priceLabel?: string | null;
  package_category?: string | null;
  room_category?: string | null;
  schedule_mode?: ScheduleMode | null;
  resource_key?: string | null;
  fixed_start_time?: string | null;
  fixed_end_time?: string | null;
  duration_minutes?: number | null;
  operating_start_time?: string | null;
  operating_end_time?: string | null;
  service_type: string;
  cottage_fee?: number | null;
  min_guest_count?: number | null;
  pool_access_fee?: number | null;
  pricing_mode?: "fixed" | "per_guest" | "per_night" | null;
  resource_mode?: "exclusive" | "shared_capacity" | "admin_assign" | null;
};

type BookingVariantRow = {
  guest_capacity: number | null;
  has_aircon: boolean | null;
  id: string;
  name: string;
  package_id: string;
  price: number;
  schedule_mode?: ScheduleMode | null;
  resource_key?: string | null;
  fixed_start_time?: string | null;
  fixed_end_time?: string | null;
  duration_minutes?: number | null;
  operating_start_time?: string | null;
  operating_end_time?: string | null;
};

type BookingAddonRow = {
  compatible_services: string[];
  description: string;
  id: string;
  name: string;
  price: number;
  service_type: string | null;
};

type BookingMenuItem = {
  category: string;
  id: string;
  is_active: boolean;
  is_available: boolean;
  name: string;
  price: number;
};

function readBookingDraft(): Partial<BookingDraft> {
  try {
    const draft = JSON.parse(sessionStorage.getItem(bookingDraftKey) ?? "{}");
    if (draft.service === "Resort + Catering") draft.service = "Catering";
    return draft;
  } catch {
    sessionStorage.removeItem(bookingDraftKey);
    return {};
  }
}

const confirmationStatusLabel = (status: string, pendingLabel: string) => {
  const normalized = status.trim().toLowerCase();
  if (!normalized || normalized === "status unavailable") return "Status unavailable";
  if (normalized === "pending") return pendingLabel;
  return normalized.replace(/[_-]+/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
};

function ReservationFlow({
  onRequireLogin,
  customerProfile,
  requestedService,
}: {
  onRequireLogin?: () => void;
  customerProfile?: CustomerAccountProfile | null;
  requestedService?: string;
}) {
  const { session } = useAuth();
  const [initialDraft] = useState(() => readBookingDraft());
  const [clientRequestId, setClientRequestId] = useState(initialDraft.clientRequestId ?? crypto.randomUUID());
  const [step, setStep] = useState(initialDraft.step ?? 1);
  const [service, setService] = useState(initialDraft.service ?? "");
  const [selectedDate, setSelectedDate] = useState<Date | null>(() => initialDraft.selectedDate ? new Date(initialDraft.selectedDate) : null);
  const [month, setMonth] = useState(() => {
    if (initialDraft.month) return new Date(initialDraft.month);
    const today = new Date();
    return new Date(today.getFullYear(), today.getMonth(), 1);
  });
  const [selectedPackageId, setSelectedPackageId] = useState(initialDraft.selectedPackageId ?? initialDraft.selectedPackage ?? "");
  const [selectedVariantId, setSelectedVariantId] = useState(initialDraft.selectedVariantId ?? "");
  const [guests, setGuests] = useState(initialDraft.guests ?? 50);
  const [guestName, setGuestName] = useState(initialDraft.guestName ?? "");
  const [email, setEmail] = useState(initialDraft.email ?? "");
  const [phone, setPhone] = useState(initialDraft.phone ?? "");
  const [addOns, setAddOns] = useState<string[]>(initialDraft.addOns ?? []);
  const [itemQuantity, setItemQuantity] = useState(initialDraft.itemQuantity ?? 1);
  const [adults, setAdults] = useState(initialDraft.adults ?? 2);
  const [children, setChildren] = useState(initialDraft.children ?? 0);
  const [rooms, setRooms] = useState(initialDraft.rooms ?? 1);
  const [nights, setNights] = useState(initialDraft.nights ?? 1);
  const [cottageSelected, setCottageSelected] = useState(initialDraft.cottageSelected ?? false);
  const [poolAccessSelected, setPoolAccessSelected] = useState(initialDraft.poolAccessSelected ?? false);
  const [specialRequests, setSpecialRequests] = useState(initialDraft.specialRequests ?? "");
  const [startTime, setStartTime] = useState(initialDraft.startTime ?? "");
  const [endTime, setEndTime] = useState(initialDraft.endTime ?? "");
  const [menuSelections, setMenuSelections] = useState<Record<string, string>>(initialDraft.menuSelections ?? {});
  const [activeMenuCategory, setActiveMenuCategory] = useState("Beef");
  const [conflictReason, setConflictReason] = useState("");
  const [confirmationCode, setConfirmationCode] = useState("");
  const [createdReservation, setCreatedReservation] = useState<{ id: string; code: string } | null>(null);
  const [confirmationStatuses, setConfirmationStatuses] = useState({ payment: "Status unavailable", booking: "Status unavailable" });
  const [confirmationReceiptSaved, setConfirmationReceiptSaved] = useState(false);
  const [pendingPaymentProofPath, setPendingPaymentProofPath] = useState("");
  const submittingBooking = useRef(false);
  const [bookingSubmitting, setBookingSubmitting] = useState(false);
  const [bookingError, setBookingError] = useState("");
  const [catalogError, setCatalogError] = useState("");
  const [addonError, setAddonError] = useState("");
  const [addonLoading, setAddonLoading] = useState(false);
  const [variantError, setVariantError] = useState("");
  const [variantLoading, setVariantLoading] = useState(false);
  const [menuError, setMenuError] = useState("");
  const [menuCatalogState, setMenuCatalogState] = useState<"loading" | "ready" | "legacy" | "error">("loading");
  const [databasePackages, setDatabasePackages] = useState<BookingPackageRow[]>([]);
  const [databaseVariants, setDatabaseVariants] = useState<BookingVariantRow[]>([]);
  const [databaseAddons, setDatabaseAddons] = useState<BookingAddonRow[]>([]);
  const [databaseMenuItems, setDatabaseMenuItems] = useState<BookingMenuItem[]>([]);
  const [paymentMethod, setPaymentMethod] = useState<CustomerPaymentMethod>(initialDraft.paymentMethod ?? "gcash");
  const [paymentAmount, setPaymentAmount] = useState(initialDraft.paymentAmount ?? "");
  const [paymentReference, setPaymentReference] = useState(initialDraft.paymentReference ?? "");
  const [paymentProof, setPaymentProof] = useState<File | null>(null);
  const [paymentProofPreview, setPaymentProofPreview] = useState("");
  const paymentProofInput = useRef<HTMLInputElement | null>(null);
  const [paymentOptionsLoading, setPaymentOptionsLoading] = useState(false);
  const [paymentOptionsError, setPaymentOptionsError] = useState("");
  const [paymentAccounts, setPaymentAccounts] = useState<CustomerPaymentAccount[]>([]);
  const [paymentAccountsConfigured, setPaymentAccountsConfigured] = useState(false);
  const [paymentInstructions, setPaymentInstructions] = useState<Record<string, string>>({});
  const [demoPaymentMode, setDemoPaymentMode] = useState(true);

  useEffect(() => {
    if (!paymentProof) {
      setPaymentProofPreview("");
      return;
    }
    const previewUrl = URL.createObjectURL(paymentProof);
    setPaymentProofPreview(previewUrl);
    return () => URL.revokeObjectURL(previewUrl);
  }, [paymentProof]);

  useEffect(() => {
    let active = true;
    if (!session) {
      setPaymentAccounts([]);
      setPaymentAccountsConfigured(false);
      setPaymentInstructions({});
      setPaymentOptionsError("");
      setPaymentOptionsLoading(false);
      return () => { active = false; };
    }
    setPaymentOptionsLoading(true);
    void supabase.rpc("evently_customer_payment_options").then(({ data, error }) => {
      if (!active) return;
      setPaymentOptionsLoading(false);
      if (error) {
        setPaymentOptionsError(error.message);
        return;
      }
      const options = data && typeof data === "object" ? data as {
        accounts?: unknown;
        configured?: boolean;
        demo_mode?: boolean;
        legacy_instructions?: Record<string, string>;
      } : {};
      setPaymentAccounts(Array.isArray(options.accounts) ? options.accounts as CustomerPaymentAccount[] : []);
      setPaymentAccountsConfigured(options.configured === true);
      setPaymentInstructions(options.legacy_instructions ?? {});
      setDemoPaymentMode(options.demo_mode !== false);
      setPaymentOptionsError("");
    });
    return () => { active = false; };
  }, [session]);

  useEffect(() => {
    let active = true;
    const loadPackages = () => {
      void supabase.from("packages").select("*").eq("is_active", true).then((packages) => {
        if (!active) return;
        setCatalogError(packages.error?.message ?? "");
        if (!packages.error) setDatabasePackages((packages.data ?? []) as BookingPackageRow[]);
      });
    };
    const loadMenu = () => {
      void supabase.from("catering_menu_items").select("id,category,name,is_active,is_available,price").eq("is_active", true).eq("is_available", true).order("category").order("name").then(({ data, error }) => {
        if (!active) return;
        if (error) {
          const missingPriceColumn = /price/i.test(error.message) && /(schema cache|column|field|could not find)/i.test(error.message);
          if (missingPriceColumn) {
            setMenuCatalogState("legacy");
            setMenuError("The catalog-pricing migration is pending. Showing the existing menu so customers can continue booking.");
            return;
          }
          setMenuCatalogState("error");
          setMenuError(error.message);
          return;
        }
        setMenuError("");
        setDatabaseMenuItems(((data ?? []) as BookingMenuItem[]).filter((item) =>
          item.is_active === true && item.is_available === true,
        ));
        setMenuCatalogState("ready");
      });
    };
    const refresh = () => { loadPackages(); loadMenu(); };
    refresh();
    window.addEventListener("evently-catalog-changed", refresh);
    const channel = supabase.channel("customer-evently-catalog")
      .on("postgres_changes", { event: "*", schema: "public", table: "packages" }, loadPackages)
      .on("postgres_changes", { event: "*", schema: "public", table: "catering_menu_items" }, loadMenu)
      .subscribe();
    return () => {
      active = false;
      window.removeEventListener("evently-catalog-changed", refresh);
      void supabase.removeChannel(channel);
    };
  }, []);

  useEffect(() => {
    let active = true;
    const compatibleService = service.trim().toLowerCase();
    setDatabaseAddons([]);
    setAddonError("");
    if (!compatibleService) {
      setAddonLoading(false);
      return () => { active = false; };
    }
    setAddonLoading(true);
    const loadAddons = () => {
      void supabase.from("addons")
        .select("id,name,description,service_type,compatible_services,price,is_active")
        .eq("is_active", true)
        .contains("compatible_services", [compatibleService])
        .then(({ data, error }) => {
        if (!active) return;
        setAddonLoading(false);
        setAddonError(error?.message ?? "");
        if (!error) setDatabaseAddons((data ?? []) as BookingAddonRow[]);
      });
    };
    setAddonLoading(true);
    loadAddons();
    window.addEventListener("evently-catalog-changed", loadAddons);
    const channel = supabase.channel(`customer-evently-addons-${compatibleService}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "addons" }, loadAddons)
      .subscribe();
    return () => {
      active = false;
      window.removeEventListener("evently-catalog-changed", loadAddons);
      void supabase.removeChannel(channel);
    };
  }, [service]);

  useEffect(() => {
    if (!customerProfile) return;
    if (!guestName) setGuestName(customerProfile.fullName);
    if (!email) setEmail(customerProfile.email);
    if (!phone) setPhone(customerProfile.mobile);
  }, [customerProfile, email, guestName, phone]);

  useEffect(() => {
    if (!requestedService || !serviceById(requestedService)) return;
    setService(requestedService);
    setGuests(requestedService === "Swimming Pool" ? 1 : requestedService === "Room Accommodation" ? 4 : 50);
    setSelectedPackageId("");
    setSelectedVariantId("");
    setAddOns([]);
    setCottageSelected(false);
    setPoolAccessSelected(false);
    setMenuSelections({});
    setStep(1);
  }, [requestedService]);

  useEffect(() => {
    if (addonLoading || addonError) return;
    const compatibleNames = new Set(databaseAddons
      .map((item) => item.name));
    setAddOns((current) => {
      const compatible = current.filter((name) => compatibleNames.has(name));
      return compatible.length === current.length ? current : compatible;
    });
  }, [addonError, addonLoading, databaseAddons, selectedPackageId, service]);

  useEffect(() => {
    if (menuCatalogState === "loading" || menuCatalogState === "error") return;
    const availableItems = menuCatalogState === "legacy"
      ? new Set(cateringMenu.flatMap(({ key, items }) => items.map((name) => `${normalizeMenuCategory(key)}::${name.trim().toLowerCase()}`)))
      : new Set(databaseMenuItems.map((item) => `${normalizeMenuCategory(item.category)}::${item.name.trim().toLowerCase()}`));
    setMenuSelections((current) => Object.fromEntries(
      Object.entries(current).filter(([category, name]) => availableItems.has(`${normalizeMenuCategory(category)}::${name.trim().toLowerCase()}`)),
    ));
  }, [databaseMenuItems, menuCatalogState]);

  useEffect(() => {
    if (step === 9) {
      sessionStorage.removeItem(bookingDraftKey);
      return;
    }
    const draft: BookingDraft = {
      clientRequestId,
      step,
      service,
      selectedDate: selectedDate?.toISOString() ?? null,
      month: month.toISOString(),
      selectedPackageId,
      selectedVariantId,
      guests,
      guestName,
      email,
      phone,
      addOns,
      itemQuantity,
      adults,
      children,
      rooms,
      nights,
      cottageSelected,
      poolAccessSelected,
      specialRequests,
      startTime,
      endTime,
      menuSelections,
      paymentMethod,
      paymentAmount,
      paymentReference,
    };
    sessionStorage.setItem(bookingDraftKey, JSON.stringify(draft));
  }, [addOns, adults, children, clientRequestId, cottageSelected, email, endTime, guestName, guests, itemQuantity, menuSelections, month, nights, paymentAmount, paymentMethod, paymentReference, phone, poolAccessSelected, rooms, selectedDate, selectedPackageId, selectedVariantId, service, specialRequests, startTime, step]);

  const steps = service === "Catering"
    ? [
      { id: 1, label: "Choose Service" },
      { id: 2, label: "Choose Date" },
      { id: 3, label: "Choose Package" },
      { id: 4, label: "Select Menu / Ulam" },
      { id: 5, label: "Customer Information" },
      { id: 6, label: "Recommended Add-ons" },
      { id: 7, label: "Review Booking" },
      { id: 8, label: "Payment" },
      { id: 9, label: "Booking Status" },
    ]
    : [
      { id: 1, label: "Choose Service" },
      { id: 2, label: "Choose Date" },
      { id: 3, label: "Choose Package" },
      { id: 5, label: "Customer Information" },
      { id: 6, label: "Recommended Add-ons" },
      { id: 7, label: "Review Booking" },
      { id: 8, label: "Payment" },
      { id: 9, label: "Booking Status" },
    ];
  const progressIndex = Math.max(0, steps.findIndex(({ id }) => id === step));
  const activeService = serviceById(service);
  const packageOptions = databasePackages
    .filter((item) => {
      if (service === "Swimming Pool") return normalizedService(item.service_type) === "resort"
        && (item.package_category?.trim().toLowerCase() === "pool_tour" || swimmingPackageNames.has(item.name.trim().toLowerCase()));
      if (service === "Event") {
        return item.package_category?.trim().toLowerCase() === "event_venue";
      }
      if (service !== "Room Accommodation") {
        return normalizedService(item.service_type) === normalizedService(service)
          || (normalizedService(service) === "food" && normalizedService(item.service_type) === "food");
      }
      if (normalizedService(item.service_type) !== "resort") return false;
      const explicitCategory = item.room_category ?? item.package_category ?? item.category;
      if (explicitCategory) {
        const normalizedCategory = explicitCategory.trim().toLowerCase();
        return normalizedCategory.includes("room") || normalizedCategory.includes("accommodation");
      }
      return roomPackageNames.has(item.name.trim().toLowerCase());
    })
    .map((item) => {
      const designPackage = activeService?.packages.find((candidate) => item.name.toLowerCase().includes(candidate.name.toLowerCase()) || candidate.name.toLowerCase().includes(item.name.toLowerCase().replace(" package", "")));
      const useDatabaseRoomDetails = service === "Room Accommodation";
      return {
        ...item,
        detail: item.description || (useDatabaseRoomDetails ? "Room details are not configured." : designPackage?.detail || "Configured Evently package"),
        inclusions: item.menu_items ?? (useDatabaseRoomDetails ? [] : designPackage?.inclusions ?? []),
        popular: useDatabaseRoomDetails ? false : designPackage?.popular,
      };
    });
  const packageChoice = packageOptions.find((item) => item.id === selectedPackageId)
    ?? packageOptions.find((item) => item.name === selectedPackageId);
  useEffect(() => {
    if (packageChoice && selectedPackageId !== packageChoice.id) {
      setSelectedPackageId(packageChoice.id);
    }
  }, [packageChoice, selectedPackageId]);
  useEffect(() => {
    let active = true;
    if (!packageChoice) {
      setDatabaseVariants([]);
      setSelectedVariantId("");
      setVariantError("");
      setVariantLoading(false);
      return () => { active = false; };
    }
    setVariantLoading(true);
    setVariantError("");
    const loadVariants = () => {
      void supabase.from("package_variants")
        .select("*")
        .eq("package_id", packageChoice.id)
        .eq("is_active", true)
        .then(({ data, error }) => {
        if (!active) return;
        setVariantLoading(false);
        if (error) {
          setDatabaseVariants([]);
          setVariantError(error.message);
          return;
        }
        const variants = (data ?? []) as BookingVariantRow[];
        setDatabaseVariants(variants);
        setSelectedVariantId((current) => {
          if (variants.some((variant) => variant.id === current)) return current;
          return variants.length === 1 ? variants[0].id : "";
        });
      });
    };
    loadVariants();
    window.addEventListener("evently-catalog-changed", loadVariants);
    const channel = supabase.channel(`customer-evently-variants-${packageChoice.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "package_variants", filter: `package_id=eq.${packageChoice.id}` }, loadVariants)
      .subscribe();
    return () => {
      active = false;
      window.removeEventListener("evently-catalog-changed", loadVariants);
      void supabase.removeChannel(channel);
    };
  }, [packageChoice?.id]);
  const packageVariants = packageChoice
    ? databaseVariants.filter((variant) => variant.package_id === packageChoice.id)
    : [];
  const selectedVariant = packageVariants.find((variant) => variant.id === selectedVariantId);
  const variantRequired = packageVariants.length > 1;
  const serviceSchedule = serviceScheduleDefaults[service] ?? { mode: "admin_assign" as const };
  const scheduleMode = selectedVariant?.schedule_mode ?? packageChoice?.schedule_mode ?? serviceSchedule.mode;
  const configuredStartTime = selectedVariant?.fixed_start_time ?? packageChoice?.fixed_start_time ?? serviceSchedule.start ?? "";
  const configuredEndTime = selectedVariant?.fixed_end_time ?? packageChoice?.fixed_end_time ?? serviceSchedule.end ?? "";
  const requiredDuration = selectedVariant?.duration_minutes ?? packageChoice?.duration_minutes ?? serviceSchedule.durationMinutes ?? null;
  const operatingStart = selectedVariant?.operating_start_time ?? packageChoice?.operating_start_time ?? "";
  const operatingEnd = selectedVariant?.operating_end_time ?? packageChoice?.operating_end_time ?? "";
  const reservationStartTime = scheduleMode === "fixed" ? configuredStartTime : startTime;
  const reservationEndTime = scheduleMode === "fixed"
    ? configuredEndTime
    : requiredDuration && startTime ? addScheduleMinutes(startTime, requiredDuration) : endTime;
  const reservationDuration = scheduleDuration(reservationStartTime, reservationEndTime);
  const validReservationTime = Boolean(
    reservationStartTime
    && reservationEndTime
    && reservationDuration > 0
    && (requiredDuration === null || reservationDuration === requiredDuration),
  );
  const operatingHoursConfigured = scheduleMode !== "customer_select" || Boolean(operatingStart && operatingEnd);
  const withinOperatingHours = scheduleMode !== "customer_select"
    || (operatingHoursConfigured && scheduleWithinWindow(reservationStartTime, reservationEndTime, operatingStart, operatingEnd));
  const scheduleReady = scheduleMode === "untimed"
    || scheduleMode === "admin_assign"
    || (validReservationTime && withinOperatingHours);
  const selectedPackageLabel = packageChoice
    ? selectedVariant ? `${packageChoice.name} · ${selectedVariant.name}` : packageChoice.name
    : "";
  const effectiveGuestCapacity = selectedVariant?.guest_capacity ?? packageChoice?.guest_capacity ?? null;
  const effectiveUnitPrice = selectedVariant?.price ?? packageChoice?.price ?? 0;
  const minimumGuests = packageChoice?.min_guest_count ?? 1;
  const cottageFee = cottageSelected ? packageChoice?.cottage_fee ?? 0 : 0;
  const poolAccessFee = poolAccessSelected ? packageChoice?.pool_access_fee ?? 0 : 0;
  const packagePrice = !packageChoice
    ? 0
    : activeService?.quantityMode === "items"
      ? effectiveUnitPrice * itemQuantity
      : activeService?.quantityMode === "tour"
        ? effectiveUnitPrice * guests + cottageFee
        : activeService?.quantityMode === "rooms"
          ? effectiveUnitPrice * rooms * nights
          : effectiveUnitPrice;
  const addOnOptions = databaseAddons.map((item) => ({ ...item, imageContext: `${item.name} Photo` }));
  const validatedAddOns = addOnOptions.filter((item) => addOns.includes(item.name));
  const addOnTotal = validatedAddOns.reduce((total, item) => total + item.price, 0);
  const selectedMenuTotal = service === "Catering"
    ? requiredMenuCategories.reduce((total, category) => {
      const item = databaseMenuItems.find((candidate) => normalizeMenuCategory(candidate.category) === normalizeMenuCategory(category) && candidate.name.trim().toLowerCase() === menuSelections[category]?.trim().toLowerCase() && candidate.is_active === true && candidate.is_available === true);
      return total + Number(item?.price ?? 0) * guests;
    }, 0)
    : 0;
  const subtotal = packagePrice + poolAccessFee + addOnTotal + selectedMenuTotal;
  const menuOptions = cateringMenu.map(({ key }) => ({
    key,
    items: menuCatalogState === "legacy"
      ? (cateringMenu.find((category) => category.key === key)?.items ?? []).map((name) => ({
        id: `legacy:${key}:${name}`,
        category: key,
        name,
        price: 0,
        is_active: true,
        is_available: true,
      }))
      : databaseMenuItems.filter((item) => normalizeMenuCategory(item.category) === normalizeMenuCategory(key) && item.is_active === true && item.is_available === true),
  }));
  const depositPercentage = normalizeDepositPercentage(packageChoice?.deposit_percentage);
  const deposit = calculateRequiredDeposit(subtotal, depositPercentage);
  const requiredPaymentAmount = deposit > 0 ? deposit : subtotal;
  const remaining = subtotal;
  const currency = formatPhp;
  const menuComplete = requiredMenuCategories.every((category) => Boolean(menuSelections[category]));
  const supportedPaymentMethods: CustomerPaymentMethod[] = ["gcash", "maya", "bank_transfer"];
  const activePaymentAccounts = paymentAccounts.filter((account) => account.is_active
    && supportedPaymentMethods.includes(account.method)
    && Boolean(account.display_name?.trim() && account.instructions?.trim())
    && (account.method === "bank_transfer"
      ? Boolean(account.bank_name?.trim() && account.account_number?.trim() && account.account_holder?.trim())
      : Boolean(account.mobile_wallet_number?.trim() && account.account_holder?.trim())));
  const availablePaymentMethods = Array.from(new Set(activePaymentAccounts.map((account) => account.method)));
  const selectedPaymentAccount = activePaymentAccounts.find((account) => account.method === paymentMethod) ?? null;
  const selectedPaymentInstructions = selectedPaymentAccount?.instructions ?? "";

  useEffect(() => {
    if (availablePaymentMethods.length && !availablePaymentMethods.includes(paymentMethod)) {
      setPaymentMethod(availablePaymentMethods[0]);
    }
  }, [availablePaymentMethods.join("|"), paymentMethod]);

  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const firstDay = new Date(month.getFullYear(), month.getMonth(), 1);
  const startOffset = firstDay.getDay();
  const daysInMonth = new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate();
  const calendarDays = Array.from({ length: 42 }, (_, index) => {
    const day = index - startOffset + 1;
    return day > 0 && day <= daysInMonth ? day : null;
  });
  const dateKey = (date: Date) =>
    `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;

  const getStatus = (day: number): AvailabilityStatus => {
    const date = new Date(month.getFullYear(), month.getMonth(), day);
    if (date < today || date.getDay() === 0) return "unavailable";
    return "available";
  };

  const selectDate = (day: number) => {
    const status = getStatus(day);
    if (status === "unavailable") return;
    setBookingError("");
    setConflictReason("");
    setSelectedDate(new Date(month.getFullYear(), month.getMonth(), day));
  };

  const changeMonth = (direction: number) => {
    setMonth((current) => new Date(current.getFullYear(), current.getMonth() + direction, 1));
    setConflictReason("");
  };

  const toggleAddOn = (name: string) => {
    if (!addOnOptions.some((item) => item.name === name)) return;
    setAddOns((current) =>
      current.includes(name) ? current.filter((item) => item !== name) : [...current, name],
    );
  };

  const canContinue =
    (step === 1 && Boolean(service)) ||
    (step === 2 && Boolean(selectedDate) && !conflictReason && (
      scheduleMode !== "customer_select" || Boolean(startTime && reservationEndTime)
    )) ||
    (step === 3 && Boolean(packageChoice) && !variantLoading && !variantError && scheduleReady && (
      !variantRequired || Boolean(selectedVariant)
    ) && (
      activeService?.quantityMode !== "tour" || guests >= minimumGuests
    )) ||
    (step === 4 && service === "Catering" && menuComplete) ||
    (step === 5 && Boolean(guestName && email && normalizePhilippineMobile(phone)) && guests > 0 && (
      effectiveGuestCapacity == null || guests <= effectiveGuestCapacity
    )) ||
    step === 6 ||
    step === 7 ||
    (step === 8 && Boolean(
      paymentMethod
      && availablePaymentMethods.includes(paymentMethod)
      && paymentReference.trim()
      && Number.isFinite(Number(paymentAmount))
      && Number(paymentAmount) > 0
      && Number(paymentAmount) <= subtotal
      && subtotal > 0
      && paymentProof
      && !paymentOptionsLoading
      && !paymentOptionsError
    ));

  const nextStep = async () => {
    if (!canContinue || conflictReason) return;
    if (step === 3 && packageChoice && selectedDate) {
      const { data: available, error } = await supabase.rpc("evently_check_availability", {
        p_package_id: packageChoice.id,
        p_reservation_date: dateKey(selectedDate),
      });
      if (error) {
        setBookingError(`Availability could not be checked: ${error.message}`);
        setConflictReason("");
        return;
      }
      if (!available) {
        setBookingError("");
        setConflictReason("This package is not eligible for the selected date. This does not represent a confirmed venue or time-slot overlap.");
        setStep(2);
        return;
      }
    }
    if (step === 7 && !session) {
      onRequireLogin?.();
      return;
    }
    if (step === 8) {
      if (submittingBooking.current) return;
      submittingBooking.current = true;
      setBookingSubmitting(true);
      let reservationForRetry = createdReservation;
      try {
        const { data: authData } = await supabase.auth.getSession();
        if (!authData.session) {
          onRequireLogin?.();
          return;
        }
        if (!packageChoice || !selectedDate) throw new Error("Select an available database package and reservation date.");
        if (!normalizePhilippineMobile(phone)) throw new Error("Enter a valid Philippine mobile number in 09XXXXXXXXX format.");
        if (!paymentProof) throw new Error("Upload a JPG, PNG, or WebP payment receipt.");
        if (!supportedPaymentMethods.includes(paymentMethod) || !availablePaymentMethods.includes(paymentMethod)) {
          throw new Error("Select an active GCash, Maya, or Bank Transfer method.");
        }
        const amount = Number(paymentAmount);
        if (!Number.isFinite(amount) || amount <= 0 || amount > subtotal) throw new Error("Enter the amount you actually paid. It must be greater than zero and no more than the booking total.");
        if (!paymentReference.trim() || paymentReference.trim().length > 160) {
          throw new Error("Enter a transaction reference number (160 characters or fewer).");
        }
        if (!["image/jpeg", "image/png", "image/webp"].includes(paymentProof.type) || paymentProof.size > 5 * 1024 * 1024) {
          throw new Error("Receipt must be a JPG, PNG, or WebP image no larger than 5 MB.");
        }
        if (["fixed", "customer_select"].includes(scheduleMode) && !validReservationTime) {
          throw new Error(scheduleMode === "fixed"
            ? "This package has an invalid configured schedule. Contact the administrator."
            : "Select a valid start and end time.");
        }
        let reservation = reservationForRetry;
        if (!reservation) {
          const { data, error } = await supabase.rpc("create_evently_reservation", {
            p_booking: {
              addons: validatedAddOns.map(({ id }) => ({ id })),
              customer_email: email.trim(),
              customer_name: guestName.trim(),
              customer_phone: normalizePhilippineMobile(phone) || phone.trim(),
              guest_count: guests,
              booking_service: service,
              idempotency_key: clientRequestId,
              menu: service === "Catering" ? menuSelections : {},
              package_id: packageChoice.id,
              package_variant_id: selectedVariant?.id ?? null,
              reservation_date: dateKey(selectedDate),
              start_time: reservationStartTime ? `${reservationStartTime.slice(0, 5)}:00` : null,
              end_time: reservationEndTime ? `${reservationEndTime.slice(0, 5)}:00` : null,
              cottage_selected: cottageSelected,
              pool_access_selected: poolAccessSelected,
              item_quantity: itemQuantity,
              rooms,
              nights,
              special_requests: specialRequests.trim() || null,
            },
          });
          if (error) throw error;
          const result = data as { reservation_id?: string; reservation_code?: string } | null;
          if (!result?.reservation_id || !result.reservation_code) {
            throw new Error("The reservation was not confirmed by the database.");
          }
          reservation = { id: result.reservation_id, code: result.reservation_code };
          reservationForRetry = reservation;
          setCreatedReservation(reservation);
        }

        let proofPath = pendingPaymentProofPath;
        if (!proofPath) {
          const proofExtension = paymentProof.type === "image/jpeg" ? "jpg" : paymentProof.type === "image/png" ? "png" : "webp";
          proofPath = `${authData.session.user.id}/${crypto.randomUUID()}.${proofExtension}`;
          const upload = await supabase.storage.from("payment-proofs").upload(proofPath, paymentProof, {
            contentType: paymentProof.type,
            upsert: false,
          });
          if (upload.error) throw upload.error;
          setPendingPaymentProofPath(proofPath);
        }

        const { error: paymentError } = await supabase.rpc("evently_submit_payment_proof", {
          p_reservation_id: reservation.id,
          p_amount: amount,
          p_method: paymentMethod,
          p_reference_number: paymentReference.trim(),
          p_proof_path: proofPath,
        });
        if (paymentError) throw paymentError;

        try {
          const [savedReservation, savedPayment] = await Promise.all([
            supabase.from("reservations").select("*").eq("id", reservation.id).maybeSingle(),
            supabase.from("payments").select("*").eq("reservation_id", reservation.id)
              .order("created_at", { ascending: false }).limit(1).maybeSingle(),
          ]);
          setConfirmationStatuses({
            booking: savedReservation.data
              ? rowText(savedReservation.data as CustomerDataRow, ["booking_status", "reservation_status", "status"], "Status unavailable")
              : "Status unavailable",
            payment: savedPayment.data
              ? rowText(savedPayment.data as CustomerDataRow, ["verification_status", "payment_status", "status"], "Status unavailable")
              : "Status unavailable",
          });
        } catch {
          setConfirmationStatuses({ payment: "Status unavailable", booking: "Status unavailable" });
        }
        // The receipt upload and payment-proof RPC both succeeded before this point.
        setConfirmationReceiptSaved(true);

        setConfirmationCode(reservation.code);
        setBookingError("");
        window.dispatchEvent(new Event(customerBookingsChangedEvent));
        window.dispatchEvent(new Event("evently-admin-data-changed"));
        setStep(9);
      } catch (error) {
        const message = error && typeof error === "object" && "message" in error
          ? String(error.message)
          : "The booking and payment proof could not be submitted.";
        setBookingError(reservationForRetry
          ? `Payment proof was not submitted: ${message} Your booking ${reservationForRetry.code} is saved. Retry to submit payment without creating another reservation.`
          : message);
        return;
      } finally {
        submittingBooking.current = false;
        setBookingSubmitting(false);
      }
      return;
    }
    setStep((current) => current === 3 && service !== "Catering" ? 5 : Math.min(8, current + 1));
  };

  const resetBooking = () => {
    setStep(1);
    setClientRequestId(crypto.randomUUID());
    setService("");
    setSelectedDate(null);
    setSelectedPackageId("");
    setSelectedVariantId("");
    setCottageSelected(false);
    setPoolAccessSelected(false);
    setDatabaseVariants([]);
    setGuests(50);
    setGuestName("");
    setEmail("");
    setPhone("");
    setAddOns([]);
    setItemQuantity(1);
    setAdults(2);
    setChildren(0);
    setRooms(1);
    setNights(1);
    setStartTime("");
    setEndTime("");
    setSpecialRequests("");
    setMenuSelections({});
    setPaymentMethod("gcash");
    setPaymentAmount("");
    setPaymentReference("");
    setPaymentProof(null);
    if (paymentProofInput.current) paymentProofInput.current.value = "";
    setActiveMenuCategory("Beef");
    setConflictReason("");
    setConfirmationCode("");
    setCreatedReservation(null);
    setConfirmationStatuses({ payment: "Status unavailable", booking: "Status unavailable" });
    setConfirmationReceiptSaved(false);
    setPendingPaymentProofPath("");
    submittingBooking.current = false;
    setBookingSubmitting(false);
    setBookingError("");
  };

  return (
      <section className="reservation-section" data-booking-flow-active={step > 1 || Boolean(service) || bookingSubmitting ? "true" : undefined} id="booking">
      <div className="reservation-intro">
        <span className="section-kicker">Reserve with confidence</span>
        <h2>Plan your Venice<br /><em>experience.</em></h2>
        <p>Choose your service and date. We will keep every detail clear as you build your booking.</p>
      </div>

      <div className={`reservation-shell${step === 9 ? " reservation-shell--confirmation" : ""}`}>
        <div className="reservation-progress" aria-label={`Reservation step ${progressIndex + 1} of ${steps.length}`}>
          <div className="reservation-progress__desktop">
            {steps.map(({ id, label }, index) => (
              <div
                className={`progress-step ${progressIndex === index ? "progress-step--current" : progressIndex > index ? "progress-step--complete" : ""}`}
                key={id}
              >
                <span>{progressIndex > index ? "✓" : index + 1}</span>
                <small>{label}</small>
              </div>
            ))}
          </div>
          <div className="reservation-progress__compact">
            <div>
              <span>Step {progressIndex + 1} of {steps.length}</span>
              <strong>{steps[progressIndex]?.label}</strong>
            </div>
            <progress max={steps.length} value={progressIndex + 1} />
          </div>
        </div>

        <div className="reservation-layout">
          <div className="reservation-main">
            {step === 1 && (
              <div className="booking-step booking-step--enter">
                <div className="booking-step__heading">
                  <span>Step 1 of {steps.length}</span>
                  <h3>What can we prepare for you?</h3>
                  <p>Select the experience that best fits your celebration.</p>
                </div>
                <div className="service-choice-grid">
                  {serviceCatalog.map((serviceOption) => (
                    <button
                      data-booking-cta="true"
                      className={`choice-card ${service === serviceOption.id ? "choice-card--selected" : ""}`}
                      key={serviceOption.id}
                      onClick={() => {
                        setService(serviceOption.id);
                        setGuests(serviceOption.id === "Swimming Pool" ? 1 : serviceOption.id === "Room Accommodation" ? 4 : 50);
                        setSelectedPackageId("");
                        setSelectedVariantId("");
                        setDatabaseVariants([]);
                        setAddOns([]);
                        setMenuSelections({});
                        setStartTime("");
                        setEndTime("");
                      }}
                      type="button"
                    >
                      <PhotoPlaceholder context={serviceOption.imageContext} compact className="choice-card__photo" />
                      <span className="choice-card__icon"><Icon name={serviceOption.label.includes("Stay") || serviceOption.label.includes("Resort") || serviceOption.label.includes("Room") ? "sun" : "sparkle"} /></span>
                      <strong>{serviceOption.label}</strong>
                      <small>{serviceOption.description}</small>
                      <span className="choice-card__check">✓</span>
                    </button>
                  ))}
                </div>
              </div>
            )}

            {step === 2 && (
              <div className="booking-step booking-step--enter">
                <div className="booking-step__heading">
                  <span>Step 2 of {steps.length}</span>
                  <h3>Choose your preferred date and time</h3>
                  <p>Select the requested schedule. Fixed resort schedules are applied automatically, while unconfigured room schedules remain subject to admin assignment.</p>
                </div>
                <div className="availability-legend">
                  <span><i className="status-dot status-dot--available" />Available</span>
                  <span><i className="status-dot status-dot--reserved" />Reserved</span>
                  <span><i className="status-dot status-dot--unavailable" />Unavailable</span>
                </div>
                {conflictReason && (
                  <div className="conflict-warning" role="alert">
                    <strong>Date Unavailable</strong>
                    <span>{conflictReason}</span>
                  </div>
                )}
                <div className="calendar">
                  <div className="calendar__header">
                    <button
                      type="button"
                      aria-label="Previous month"
                      disabled={month.getFullYear() === today.getFullYear() && month.getMonth() === today.getMonth()}
                      onClick={() => changeMonth(-1)}
                    >
                      <Icon name="chevron" />
                    </button>
                    <strong>{month.toLocaleDateString("en-PH", { month: "long", year: "numeric" })}</strong>
                    <button type="button" aria-label="Next month" onClick={() => changeMonth(1)}>
                      <Icon name="chevron" />
                    </button>
                  </div>
                  <div className="calendar__weekdays">
                    {["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map((day) => <span key={day}>{day}</span>)}
                  </div>
                  <div className="calendar__grid" key={`${month.getFullYear()}-${month.getMonth()}`}>
                    {calendarDays.map((day, index) => {
                      if (!day) return <span className="calendar__blank" key={`blank-${index}`} />;
                      const status = getStatus(day);
                      const isSelected =
                        selectedDate?.getFullYear() === month.getFullYear() &&
                        selectedDate?.getMonth() === month.getMonth() &&
                        selectedDate?.getDate() === day;
                      return (
                        <button
                          className={`calendar-day calendar-day--${status} ${isSelected ? "calendar-day--selected" : ""}`}
                          disabled={status === "unavailable"}
                          key={day}
                          onClick={() => selectDate(day)}
                          type="button"
                          aria-label={`${month.toLocaleDateString("en-PH", { month: "long" })} ${day}, ${status}`}
                        >
                          <span>{day}</span><i />
                        </button>
                      );
                    })}
                  </div>
                </div>
                <div className="booking-date-time-panel">
                  <label><span>Reservation date</span><input min={dateKey(today)} onChange={(event) => {
                    const nextDate = new Date(`${event.target.value}T00:00:00`);
                    if (!Number.isNaN(nextDate.getTime()) && nextDate >= today && nextDate.getDay() !== 0) {
                      setSelectedDate(nextDate);
                      setMonth(new Date(nextDate.getFullYear(), nextDate.getMonth(), 1));
                      setConflictReason("");
                    }
                  }} type="date" value={selectedDate ? dateKey(selectedDate) : ""} /></label>
                  {scheduleMode === "fixed" && packageChoice && <div><span>Confirmed package schedule</span><strong>{configuredStartTime.slice(0, 5)}–{configuredEndTime.slice(0, 5)}{configuredEndTime <= configuredStartTime ? " · ends the following day" : ""}</strong></div>}
                  {service === "Swimming Pool" && !packageChoice && <p>Choose Day Tour, Night Tour, or Overnight Tour in the next step. Its fixed hours will be applied automatically.</p>}
                  {scheduleMode === "customer_select" && <>
                    <label><span>Start time</span><input onChange={(event) => { const nextStart = event.target.value; setStartTime(nextStart); setEndTime(requiredDuration ? addScheduleMinutes(nextStart, requiredDuration) : ""); }} type="time" value={startTime} /></label>
                    <label><span>End time</span><input disabled={Boolean(requiredDuration)} min={requiredDuration ? undefined : startTime || undefined} onChange={(event) => setEndTime(event.target.value)} type="time" value={reservationEndTime} /></label>
                    {requiredDuration && <small>{requiredDuration / 60} hour venue duration. The end time is calculated automatically.</small>}
                    {!operatingHoursConfigured && packageChoice && <small className="booking-schedule-error" role="alert">This package does not have configured operating hours. Contact the administrator before booking.</small>}
                  </>}
                  {scheduleMode === "admin_assign" && <p>The administrator will assign and verify the time and physical venue/resource before approval.</p>}
                </div>
              </div>
            )}

            {step === 3 && (
              <div className="booking-step booking-step--enter">
                <div className="booking-step__heading">
                  <span>Step 3 of {steps.length}</span>
                  <h3>{service === "Swimming Pool" ? "Choose your tour time slot" : "Pick your package"}</h3>
                  <p>{service === "Swimming Pool" ? "Tour hours are fixed and cannot be changed." : "Each package can be refined with our team after your reservation."}</p>
                </div>
                <div className="tier-grid">
                  {packageOptions.map((tier, index) => {
                    return (
                      <button
                        className={`tier-card ${packageChoice?.id === tier.id ? "tier-card--selected" : ""}`}
                        key={tier.id}
                        onClick={() => {
                          setSelectedPackageId(tier.id);
                          setSelectedVariantId("");
                          setDatabaseVariants([]);
                          setVariantLoading(true);
                          setVariantError("");
                          setBookingError("");
                        }}
                        type="button"
                      >
                        {tier.popular && <span className="tier-card__popular">Most popular</span>}
                        <PhotoPlaceholder context={`${tier.name} Package Photo`} compact className="tier-card__photo" />
                        <span className="tier-card__number">0{index + 1}</span>
                        <strong>{tier.name}</strong>
                        <small>{tier.detail}</small>
                        {tier.guest_capacity != null && <small>Up to {tier.guest_capacity} guests</small>}
                        <ul className="tier-card__inclusions">
                          {tier.inclusions.map((inclusion) => <li key={inclusion}>✓ {inclusion}</li>)}
                        </ul>
                        <b>{tier.priceLabel ?? `from ${currency(tier.price)}`}</b>
                      </button>
                    );
                  })}
                </div>
                {catalogError && <div className="booking-inline-error" role="alert">{catalogError}</div>}
                {!catalogError && !packageOptions.length && <div className="booking-inline-error" role="alert">No active {serviceLabel(service)} packages are configured in Supabase.</div>}
                {packageChoice && variantLoading && <div className="package-variant-panel" aria-live="polite"><span>Loading package options…</span></div>}
                {packageChoice && variantError && <div className="booking-inline-error" role="alert">{variantError}</div>}
                {packageChoice && scheduleMode === "customer_select" && !operatingHoursConfigured && <div className="booking-inline-error" role="alert">This package has no configured operating hours. An administrator must configure them before timed bookings can be submitted.</div>}
                {packageChoice && scheduleMode === "customer_select" && operatingHoursConfigured && validReservationTime && !withinOperatingHours && <div className="booking-inline-error" role="alert">Select a time within the configured operating hours of {operatingStart.slice(0, 5)}–{operatingEnd.slice(0, 5)}.</div>}
                {packageChoice && !variantLoading && !variantError && packageVariants.length > 0 && (
                  <div className="package-variant-panel">
                    <div className="package-variant-panel__heading">
                      <div><span>Package options</span><strong>{packageVariants.length > 1 ? "Select a variant" : "Included option"}</strong></div>
                      {variantRequired && !selectedVariant && <small>Required to continue</small>}
                    </div>
                    <div className="package-variant-grid" role="radiogroup" aria-label={`${packageChoice.name} variants`}>
                      {packageVariants.map((variant) => (
                        <button
                          aria-checked={selectedVariant?.id === variant.id}
                          className={selectedVariant?.id === variant.id ? "package-variant-card package-variant-card--selected" : "package-variant-card"}
                          key={variant.id}
                          onClick={() => {
                            setSelectedVariantId(variant.id);
                            setBookingError("");
                          }}
                          role="radio"
                          type="button"
                        >
                          <span>{variant.name}</span>
                          <strong>{currency(variant.price)}</strong>
                          <small>{variant.guest_capacity == null ? "Capacity not specified" : `Up to ${variant.guest_capacity} guests`}</small>
                          <small>{variant.has_aircon == null ? "Aircon option not specified" : variant.has_aircon ? "Air-conditioned" : "Non-aircon"}</small>
                        </button>
                      ))}
                    </div>
                  </div>
                )}
                {packageChoice && activeService?.quantityMode === "items" && (
                  <div className="booking-quantity-panel">
                    <div><strong>Tray quantity</strong><span>Choose how many trays you need.</span></div>
                    <label><span>Quantity</span><input aria-label="Tray quantity" min="1" onChange={(event) => setItemQuantity(Math.max(1, Number(event.target.value)))} type="number" value={itemQuantity} /></label>
                  </div>
                )}
                {packageChoice && activeService?.quantityMode === "tour" && (
                  <div className="booking-quantity-panel">
                    <div><strong>Tour guests</strong><span>{configuredStartTime.slice(0, 5)}–{configuredEndTime.slice(0, 5)}{configuredEndTime <= configuredStartTime ? " · ends the following day" : ""} · {currency(effectiveUnitPrice)} per guest</span></div>
                    <label><span>Guests</span><input aria-label="Number of tour guests" min={minimumGuests} onChange={(event) => setGuests(Math.max(1, Number(event.target.value)))} type="number" value={guests} /></label>
                    {(packageChoice.cottage_fee ?? 0) > 0 && <label className="booking-option-toggle"><input checked={cottageSelected} onChange={(event) => setCottageSelected(event.target.checked)} type="checkbox" /><span>Add cottage · {currency(packageChoice.cottage_fee ?? 0)}</span></label>}
                    {guests < minimumGuests && <small className="booking-schedule-error" role="alert">This tour requires at least {minimumGuests} guests.</small>}
                  </div>
                )}
                {packageChoice && activeService?.quantityMode === "rooms" && (
                  <div className="booking-quantity-panel">
                    <div><strong>Accommodation details</strong><span>Enter the rooms and nights required.</span></div>
                    <label><span>Rooms</span><input aria-label="Number of rooms" min="1" onChange={(event) => setRooms(Math.max(1, Number(event.target.value)))} type="number" value={rooms} /></label>
                    <label><span>Nights</span><input aria-label="Number of nights" min="1" onChange={(event) => setNights(Math.max(1, Number(event.target.value)))} type="number" value={nights} /></label>
                  </div>
                )}
                {packageChoice && scheduleMode === "admin_assign" && (
                  <p className="deposit-note">This package requires an administrator to assign and verify the venue or resource and time slot before approval.</p>
                )}
                {packageChoice && service === "Event" && (packageChoice.pool_access_fee ?? 0) > 0 && (
                  <label className="booking-pool-access"><input checked={poolAccessSelected} onChange={(event) => setPoolAccessSelected(event.target.checked)} type="checkbox" /><span>Add optional pool access</span><strong>{currency(packageChoice.pool_access_fee ?? 0)}</strong></label>
                )}
                {packageChoice && service === "Catering" && (
                  <button className="menu-preview-button" onClick={() => setStep(4)} type="button">
                    Select the six included dishes, dessert, and drink <Icon name="arrow" size={17} />
                  </button>
                )}
              </div>
            )}

            {step === 4 && service === "Catering" && (
              <div className="booking-step booking-step--enter">
                <div className="booking-step__heading">
                  <span>Step 4 of {steps.length}</span>
                  <h3>Select your ulam and menu</h3>
                  <p>Choose one currently available item from each category. Rice is already included.</p>
                </div>
                {menuError && <p className={menuCatalogState === "legacy" ? "menu-catalog-warning" : "menu-catalog-error"} role={menuCatalogState === "legacy" ? "status" : "alert"}>{menuCatalogState === "legacy" ? menuError : `The live catering menu could not be loaded: ${menuError}`}</p>}
                {menuCatalogState === "loading" && <p className="menu-catalog-warning" role="status">Loading available catering menu selections…</p>}
                <div className="menu-category-tabs" role="tablist" aria-label="Catering menu categories">
                  {cateringMenu.map(({ key }) => (
                    <button
                      aria-selected={activeMenuCategory === key}
                      className={activeMenuCategory === key ? "menu-category-tab--active" : ""}
                      key={key}
                      onClick={() => setActiveMenuCategory(key)}
                      role="tab"
                      type="button"
                    >
                      <span>{menuSelections[key] ? "✓" : requiredMenuCategories.indexOf(key) + 1}</span>{key}
                    </button>
                  ))}
                </div>
                {menuOptions.filter(({ key }) => key === activeMenuCategory).map(({ key, items }) => (
                  <div className="ulam-category-panel" key={key} role="tabpanel">
                    <div className="ulam-category-panel__heading">
                      <div><span>{key}</span><h4>Choose one {key.toLowerCase()} selection</h4></div>
                      <small>{menuSelections[key] ? "Selection complete" : "Required"}</small>
                    </div>
                    {items.length ? <div className="ulam-choice-grid">
                      {items.map((item) => (
                        <label className={`ulam-choice-card ${menuSelections[key] === item.name ? "ulam-choice-card--selected" : ""}`} key={item.id}>
                          <input
                            checked={menuSelections[key] === item.name}
                            name={`menu-${key}`}
                            onChange={() => setMenuSelections((current) => ({ ...current, [key]: item.name }))}
                            type="radio"
                          />
                          <span className="ulam-choice-card__icon"><Icon name={key === "Drinks" ? "sun" : "sparkle"} size={17} /></span>
                          <strong>{item.name}</strong>
                          <small>{Number(item.price) > 0 ? `${currency(Number(item.price))} per guest` : "Included in package"}</small>
                          <span className="ulam-choice-card__check">✓</span>
                        </label>
                      ))}
                    </div> : menuCatalogState === "ready" ? <p className="menu-catalog-empty"><strong>No available items in this category</strong><span>Contact EVENTLY to choose another menu category.</span></p> : null}
                  </div>
                ))}
                <aside className="menu-selection-summary">
                  <div><span>Live menu summary</span><strong>{Object.keys(menuSelections).length} of 8 selected</strong></div>
                  <ul>
                    {requiredMenuCategories.map((category) => <li className={menuSelections[category] ? "menu-selection-complete" : ""} key={category}><span>{category}</span><strong>{menuSelections[category] || "Select an option"}</strong></li>)}
                    <li className="menu-selection-complete"><span>Rice</span><strong>Included</strong></li>
                  </ul>
                  {selectedMenuTotal > 0 && <p>Menu price: {currency(selectedMenuTotal)} for {guests} guests.</p>}
                  {!menuComplete && <p>Complete all eight menu categories to continue.</p>}
                </aside>
              </div>
            )}

            {step === 5 && (
              <div className="booking-step booking-step--enter">
                <div className="booking-step__heading">
                  <span>Step {progressIndex + 1} of {steps.length}</span>
                  <h3>Tell us about your gathering</h3>
                  <p>Your details help our team prepare the right experience.</p>
                </div>
                <div className="guest-form">
                  <label>
                    <span>Full name</span>
                    <input value={guestName} onChange={(event) => setGuestName(event.target.value)} placeholder="Your full name" />
                  </label>
                  <label className="guest-form__wide">
                    <span>Special requests</span>
                    <textarea onChange={(event) => setSpecialRequests(event.target.value)} placeholder="Accessibility needs, setup notes, or other requests" rows={4} value={specialRequests} />
                  </label>
                  <label>
                    <span>Email address</span>
                    <input type="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="you@example.com" />
                  </label>
                  <label>
                    <span>Phone number</span>
                    <input aria-invalid={Boolean(phone && !normalizePhilippineMobile(phone))} inputMode="numeric" maxLength={11} type="tel" value={phone} onChange={(event) => setPhone(event.target.value)} placeholder="09171234567" />
                    {phone && !normalizePhilippineMobile(phone) && <small className="booking-schedule-error" role="alert">Enter exactly 11 digits starting with 09 (for example, 09171234567).</small>}
                  </label>
                  <label>
                    <span>Number of guests</span>
                    <input max={effectiveGuestCapacity ?? undefined} min="1" type="number" value={guests} onChange={(event) => setGuests(Math.max(1, Number(event.target.value)))} />
                    {effectiveGuestCapacity != null && <small>Maximum capacity for {selectedPackageLabel}: {effectiveGuestCapacity} guests.</small>}
                    {effectiveGuestCapacity != null && guests > effectiveGuestCapacity && <small role="alert">Reduce the guest count to continue with this package.</small>}
                  </label>
                </div>
              </div>
            )}

            {step === 6 && (
              <div className="booking-step booking-step--enter">
                <div className="booking-step__heading">
                  <span>Step {progressIndex + 1} of {steps.length}</span>
                  <h3>Enhance Your Experience</h3>
                  <p>Make your celebration even more memorable with these optional additions.</p>
                </div>
                {addonLoading && <p className="deposit-note" aria-live="polite">Loading available add-ons…</p>}
                <div className="booking-addon-grid">
                  {addOnOptions.map((item) => {
                    const selected = addOns.includes(item.name);
                    return (
                      <article className={`booking-addon-card ${selected ? "booking-addon-card--selected" : ""}`} key={item.name}>
                        <PhotoPlaceholder context={item.imageContext || `${item.name} Photo`} compact className="booking-addon-card__photo" />
                        <div><span className="booking-addon-card__icon"><Icon name={item.name.includes("Sound") ? "sun" : "sparkle"} size={17} /></span><strong>{item.name}</strong></div>
                        <p>{item.description || "A thoughtful extra for your Venice experience."}</p>
                        <div className="booking-addon-card__action">
                          <b>+ {currency(item.price)}</b>
                          <button aria-pressed={selected} onClick={() => toggleAddOn(item.name)} type="button">{selected ? "Remove" : "Add to Booking"}</button>
                        </div>
                      </article>
                    );
                  })}
                </div>
                {addonError && <div className="booking-inline-error" role="alert">Add-ons could not be loaded: {addonError}</div>}
                {!addonLoading && !addonError && !addOnOptions.length && <p className="deposit-note">No active add-ons are configured for this service. You may continue without add-ons.</p>}
              </div>
            )}

            {step === 7 && (
              <div className="booking-step booking-step--enter review-booking">
                <div className="booking-step__heading">
                  <span>Step {progressIndex + 1} of {steps.length}</span>
                  <h3>Everything look right?</h3>
                  <p>Review your booking before reserving the schedule.</p>
                </div>
                <div className="review-banner">
                  <PhotoPlaceholder context={`${selectedPackageLabel || "Selected"} Package Photo`} compact className="review-booking-photo" />
                  <div>
                    <span>Your Venice date</span>
                    <strong>{selectedDate?.toLocaleDateString("en-PH", { weekday: "long", month: "long", day: "numeric", year: "numeric" })}</strong>
                  </div>
                </div>
                <div className="review-details">
                  <div><span>Reserved for</span><strong>{guestName}</strong></div>
                  <div><span>Contact</span><strong>{email}</strong><small>{phone}</small></div>
                  <div><span>Experience</span><strong>{serviceLabel(service)} · {selectedPackageLabel}</strong></div>
                  <div><span>Schedule</span><strong>{reservationStartTime && reservationEndTime ? `${reservationStartTime}–${reservationEndTime}` : "Pending administrator assignment"}</strong></div>
                  {selectedVariant && <div><span>Variant details</span><strong>{selectedVariant.guest_capacity == null ? "Capacity not specified" : `${selectedVariant.guest_capacity} guests`} · {selectedVariant.has_aircon == null ? "Aircon not specified" : selectedVariant.has_aircon ? "Air-conditioned" : "Non-aircon"}</strong></div>}
                  <div><span>Booking details</span><strong>
                    {activeService?.quantityMode === "items"
                      ? `${itemQuantity} tray${itemQuantity === 1 ? "" : "s"}`
                      : activeService?.quantityMode === "tour"
                        ? `${guests} guest${guests === 1 ? "" : "s"}${cottageSelected ? " · cottage requested" : ""}`
                        : activeService?.quantityMode === "rooms"
                          ? `${rooms} room${rooms === 1 ? "" : "s"} · ${nights} night${nights === 1 ? "" : "s"}`
                          : `${guests} guests`}
                  </strong></div>
                </div>
                {service === "Catering" && (
                  <div className="review-menu">
                    <h4>Selected menu</h4>
                    <div>{requiredMenuCategories.map((category) => <span key={category}><small>{category}</small><strong>{menuSelections[category]}</strong></span>)}</div>
                    <p>Rice included</p>
                  </div>
                )}
                <div className="review-menu review-addons">
                  <h4>Selected add-ons</h4>
                  {validatedAddOns.length ? <div>{validatedAddOns.map((item) => <span key={item.id}><strong>{item.name}</strong><small>{currency(item.price)}</small></span>)}</div> : <p>No additional services selected</p>}
                </div>
                <div className="review-price-summary">
                  <div><span>Base package price</span><strong>{currency(packagePrice)}</strong></div>
                  <div><span>Add-on subtotal</span><strong>{currency(addOnTotal)}</strong></div>
                  {poolAccessFee > 0 && <div><span>Optional pool access</span><strong>{currency(poolAccessFee)}</strong></div>}
                  <div><span>Total booking amount</span><strong>{currency(subtotal)}</strong></div>
                  <div><span>Required deposit · {depositPercentage}%</span><strong>{currency(deposit)}</strong></div>
                  <div><span>Remaining balance</span><strong>{currency(remaining)}</strong></div>
                </div>
                <p className="deposit-note">{depositPercentage > 0 ? `A ${depositPercentage}% deposit is configured for this package.` : "No deposit percentage is configured for this package. The business will confirm payment terms after review."}</p>
                <p className="deposit-note">Your requested schedule remains pending until Venice confirms the venue or resource and time slot.</p>
              </div>
            )}

            {step === 8 && (
              <div className="booking-step booking-step--enter booking-payment-step">
                <div className="booking-step__heading">
                  <span>Step {progressIndex + 1} of {steps.length}</span>
                  <h3>Submit payment proof</h3>
                  <p>We save your reservation first, then securely upload and submit the receipt you provide. A receipt or reference is not confirmation that money was received.</p>
                </div>
                {demoPaymentMode && <div className="booking-demo-payment-note"><strong>Demo Payment — No Actual Money Transfer</strong><span>This capstone demonstration records sample payment information for administrator review only. Do not send real funds based on this demo screen.</span></div>}
                <div className="booking-payment-summary">
                  <div><span>Package or service</span><strong>{serviceLabel(service)} · {selectedPackageLabel}</strong></div>
                  <div><span>Booking date and time</span><strong>{selectedDate?.toLocaleDateString("en-PH", { weekday: "long", month: "long", day: "numeric", year: "numeric" })} · {reservationStartTime && reservationEndTime ? `${reservationStartTime.slice(0, 5)}–${reservationEndTime.slice(0, 5)}` : "Time to be assigned by Admin"}</strong></div>
                  <div><span>Guest count</span><strong>{guests}</strong></div>
                  <div><span>Total booking price</span><strong>{currency(subtotal)}</strong></div>
                  <div><span>Required deposit</span><strong>{currency(requiredPaymentAmount)}</strong></div>
                </div>
                {!session && <p className="booking-payment-message" role="status">Sign in or create a customer account before submitting a reservation.</p>}
                {paymentOptionsLoading && <p className="booking-payment-message" role="status">Loading available payment destinations…</p>}
                {paymentOptionsError && <p className="booking-payment-message is-error" role="alert">Payment destinations could not be loaded: {paymentOptionsError}</p>}
                {!paymentOptionsLoading && !paymentOptionsError && !availablePaymentMethods.length && <p className="booking-payment-message is-error" role="alert">No active GCash, Maya, or Bank Transfer destination is configured. Please contact Venice before submitting.</p>}
                <div className="booking-payment-form">
                  <label><span>Payment method</span><select disabled={!availablePaymentMethods.length} onChange={(event) => setPaymentMethod(event.target.value as CustomerPaymentMethod)} required value={paymentMethod}>{availablePaymentMethods.map((method) => <option key={method} value={method}>{customerPaymentMethodLabels[method]}</option>)}</select></label>
                  {selectedPaymentAccount && <div className="booking-payment-destination"><strong>{selectedPaymentAccount.display_name}</strong>{selectedPaymentAccount.account_holder && <span>Account holder: {selectedPaymentAccount.account_holder}</span>}{selectedPaymentAccount.bank_name && <span>Bank: {selectedPaymentAccount.bank_name}</span>}{(selectedPaymentAccount.mobile_wallet_number || selectedPaymentAccount.account_number) && <span>Send to: {selectedPaymentAccount.mobile_wallet_number || selectedPaymentAccount.account_number}</span>}{selectedPaymentAccount.qr_code_url && <img alt={`${selectedPaymentAccount.display_name} payment QR code`} src={selectedPaymentAccount.qr_code_url} />}<p>{selectedPaymentInstructions}</p></div>}
                  <label><span>Actual amount paid (PHP)</span><input autoComplete="off" max={subtotal} min="0.01" onChange={(event) => setPaymentAmount(event.target.value)} required step="0.01" type="number" value={paymentAmount} /><small>Enter what you actually transferred. The required deposit is {currency(requiredPaymentAmount)}; payment proof will remain pending until an administrator reviews it.</small></label>
                  <label><span>Payment reference / transaction number</span><input autoComplete="off" maxLength={160} onChange={(event) => setPaymentReference(event.target.value)} placeholder={demoPaymentMode ? "Example: DEMO-GCASH-2026-001" : "Enter your transaction reference"} required value={paymentReference} /></label>
                  <label><span>Receipt screenshot (JPG, PNG, or WebP · max 5 MB)</span><input accept=".jpg,.jpeg,.png,.webp,image/jpeg,image/png,image/webp" ref={paymentProofInput} onChange={(event) => {
                    const file = event.target.files?.[0] ?? null;
                    if (file && (!["image/jpeg", "image/png", "image/webp"].includes(file.type) || file.size > 5 * 1024 * 1024)) {
                      setBookingError("Receipt must be a JPG, PNG, or WebP image no larger than 5 MB.");
                      event.target.value = "";
                      setPaymentProof(null);
                      setPendingPaymentProofPath("");
                      return;
                    }
                    setBookingError("");
                    setPendingPaymentProofPath("");
                    setPaymentProof(file);
                  }} required={!paymentProof} type="file" /></label>
                  {paymentProof && <div className="booking-receipt-preview"><img alt="Receipt screenshot preview" src={paymentProofPreview} /><div><strong>{paymentProof.name}</strong><span>{(paymentProof.size / (1024 * 1024)).toFixed(2)} MB · ready to upload</span><div><button onClick={() => paymentProofInput.current?.click()} type="button">Replace image</button><button onClick={() => { setPaymentProof(null); setPendingPaymentProofPath(""); if (paymentProofInput.current) paymentProofInput.current.value = ""; }} type="button">Remove image</button></div></div></div>}
                  <p className="booking-payment-privacy">Receipt files are stored in a private Supabase bucket. Only the submitting customer and authorized Owner/Admin accounts can access them.</p>
                  {bookingSubmitting && <p className="booking-payment-message" aria-live="polite">{createdReservation ? "Uploading receipt securely and submitting payment proof…" : "Saving your reservation, then uploading and submitting payment proof…"}</p>}
                </div>
              </div>
            )}

            {step === 9 && (
              <div className="booking-step booking-step--enter confirmation">
                <header className="confirmation__header">
                  <div className="confirmation__mark" aria-hidden="true">✓</div>
                  {confirmationReceiptSaved && <span className="section-kicker">Payment proof received</span>}
                  <h3>Your Venice moment is on its way.</h3>
                  <p>Your reservation has been submitted. Payment review and booking approval are handled separately; the reservation is not confirmed until an authorized administrator approves it.</p>
                </header>
                {demoPaymentMode && <div className="booking-demo-payment-note"><strong>Demo Payment — No Actual Money Transfer</strong><span>Your sample reference and receipt are demonstration data only.</span></div>}
                <div className="confirmation__status-grid" aria-label="Current payment and booking status">
                  <article className="confirmation__status-card"><span>Payment Status</span><strong>{confirmationStatusLabel(confirmationStatuses.payment, "Pending Verification")}</strong></article>
                  <article className="confirmation__status-card"><span>Booking Status</span><strong>{confirmationStatusLabel(confirmationStatuses.booking, "Pending Admin Approval")}</strong></article>
                </div>
                <dl className="confirmation__summary">
                  <div><dt>Booking Reference</dt><dd>{confirmationCode || "Unavailable"}</dd></div>
                  <div><dt>Selected Package</dt><dd>{selectedPackageLabel || "Package unavailable"}</dd></div>
                  <div><dt>Reservation Date</dt><dd>{selectedDate?.toLocaleDateString("en-PH", { month: "long", day: "numeric", year: "numeric" }) ?? "Date unavailable"}</dd></div>
                  <div><dt>Schedule</dt><dd>{reservationStartTime && reservationEndTime ? `${reservationStartTime.slice(0, 5)}–${reservationEndTime.slice(0, 5)}${reservationEndTime <= reservationStartTime ? " · ends the following day" : ""}` : "Pending administrator assignment"}</dd></div>
                  <div><dt>Payment Method</dt><dd>{customerPaymentMethodLabels[paymentMethod]}</dd></div>
                  <div><dt>Submitted Amount</dt><dd>{currency(Number(paymentAmount))}</dd></div>
                </dl>
                <button className="booking-primary confirmation__another" type="button" onClick={resetBooking}>Make Another Booking <Icon name="arrow" size={18} /></button>
              </div>
            )}

            {step < 9 && (
              <>
              {bookingError && <div className="booking-inline-error" role="alert">{bookingError}</div>}
              <div className="booking-controls">
                <button className="booking-back" disabled={step === 1 || (step === 8 && Boolean(createdReservation))} type="button" onClick={() => setStep((current) => current === 5 && service !== "Catering" ? 3 : Math.max(1, current - 1))}>
                  Back
                </button>
                {step === 6 && <button className="skip-offer-button" onClick={() => setStep(7)} type="button">Skip This Offer</button>}
                <button className="booking-primary" data-booking-cta="true" disabled={!canContinue || Boolean(conflictReason) || bookingSubmitting} type="button" onClick={nextStep}>
                  {step === 8 ? bookingSubmitting ? "Submitting Payment Proof…" : createdReservation ? "Retry Payment Proof" : "Submit Booking & Payment Proof" : step === 7 ? "Continue to Payment" : step === 6 ? "Continue to Review" : "Continue"} <Icon name="arrow" size={18} />
                </button>
              </div>
              </>
            )}
          </div>

          {step < 9 && (
            <aside className="reservation-summary">
              <div className="reservation-summary__top">
                <span>Your reservation</span>
                <strong>VENICE</strong>
              </div>
              <dl>
                <div><dt>Selected Service</dt><dd>{service ? serviceLabel(service) : "Not selected"}</dd></div>
                <div><dt>Reservation Date</dt><dd>{selectedDate ? selectedDate.toLocaleDateString("en-PH", { month: "short", day: "numeric", year: "numeric" }) : "Not selected"}</dd></div>
                <div><dt>Schedule</dt><dd>{reservationStartTime && reservationEndTime ? `${reservationStartTime.slice(0, 5)}–${reservationEndTime.slice(0, 5)}${reservationEndTime <= reservationStartTime ? " · next day" : ""}` : "Pending admin assignment"}</dd></div>
                <div><dt>Guest Count</dt><dd>{service ? guests : "—"}</dd></div>
                <div><dt>Selected Package</dt><dd>{selectedPackageLabel || "Not selected"}</dd></div>
                {selectedVariant && <div><dt>Variant Option</dt><dd>{selectedVariant.has_aircon == null ? selectedVariant.name : `${selectedVariant.name} · ${selectedVariant.has_aircon ? "Air-conditioned" : "Non-aircon"}`}</dd></div>}
                {activeService?.quantityMode === "items" && <div><dt>Quantity</dt><dd>{itemQuantity} tray{itemQuantity === 1 ? "" : "s"}</dd></div>}
                {activeService?.quantityMode === "tour" && <div><dt>Tour booking</dt><dd>{guests} guest{guests === 1 ? "" : "s"}{cottageSelected ? " · cottage requested" : ""}</dd></div>}
                {activeService?.quantityMode === "rooms" && <div><dt>Stay</dt><dd>{rooms} room · {nights} night</dd></div>}
                <div><dt>Selected Add-ons</dt><dd>{validatedAddOns.length ? validatedAddOns.map((item) => item.name).join(", ") : "None"}</dd></div>
              </dl>
              <div className="summary-totals">
                <div><span>Base Package Price</span><strong>{currency(packagePrice)}</strong></div>
                <div><span>Add-on Subtotal</span><strong>{currency(addOnTotal)}</strong></div>
                {packageChoice && depositPercentage > 0 && <div className="summary-deposit"><span>Deposit · {depositPercentage}%</span><strong>{currency(deposit)}</strong></div>}
                <div><span>Remaining Balance</span><strong>{currency(remaining)}</strong></div>
                <div className="summary-total"><span>Total Amount</span><strong>{currency(subtotal)}</strong></div>
              </div>
              <p><Icon name="sparkle" size={15} /> Your date is only secured after confirmation.</p>
            </aside>
          )}
        </div>
      </div>
    </section>
  );
}

function CustomerHeader() {
  const { session } = useAuth();
  const [menuOpen, setMenuOpen] = useState(false);
  const [notificationsOpen, setNotificationsOpen] = useState(false);
  const [notifications, setNotifications] = useState<CustomerDataRow[]>([]);
  const { pathname } = useLocation();
  const links = [
    ["/account/profile", "My Profile", "/account/profile"],
    ["/account/history", "Booking History", "/account/history"],
    ["/account/messages", "Messages", "/account/messages"],
    ["/#booking", "Booking", "/order"],
    ["/track-order", "Track Booking", "/track-order"],
    ["/account/settings", "Account Settings", "/account/settings"],
  ];
  const loadNotifications = useCallback(async () => {
    if (!session) return;
    const { data } = await supabase.from("notifications").select("*").eq("user_id", session.user.id).order("created_at", { ascending: false }).limit(12);
    if (data) setNotifications(data as CustomerDataRow[]);
  }, [session]);
  useEffect(() => {
    void loadNotifications();
    const interval = window.setInterval(() => { void loadNotifications(); }, 30000);
    return () => window.clearInterval(interval);
  }, [loadNotifications]);
  useEffect(() => {
    if (!session) return;
    const channel = supabase.channel(`customer-notifications-${session.user.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "notifications", filter: `user_id=eq.${session.user.id}` }, () => { void loadNotifications(); })
      .subscribe();
    return () => { void supabase.removeChannel(channel); };
  }, [loadNotifications, session]);
  const openNotifications = async () => {
    setNotificationsOpen((current) => !current);
    const unread = notifications.filter((item) => !item.is_read).map((item) => String(item.id));
    if (unread.length) {
      await supabase.rpc("mark_evently_notifications_read", { p_ids: unread });
      setNotifications((current) => current.map((item) => ({ ...item, is_read: true })));
    }
  };
  return (
    <header className="customer-header">
      <a href="/" aria-label="Back to Venice homepage"><Brand /></a>
      <button className="customer-menu-button" aria-expanded={menuOpen} aria-label={menuOpen ? "Close customer navigation" : "Open customer navigation"} onClick={() => setMenuOpen((open) => !open)} type="button">
        <Icon name={menuOpen ? "close" : "menu"} />
      </button>
      <nav className={menuOpen ? "customer-nav--open" : ""} aria-label="Customer navigation">
        {links.map(([href, label, activePath]) => <a aria-current={pathname === activePath ? "page" : undefined} className={pathname === activePath ? "customer-nav-active" : ""} href={href} key={href} onClick={() => setMenuOpen(false)}>{label}</a>)}
      </nav>
      {session && <div className="customer-notifications"><button aria-expanded={notificationsOpen} aria-label="Open notifications" onClick={() => void openNotifications()} type="button"><Icon name="bell" size={18} />{notifications.some((item) => !item.is_read) && <i />}</button>{notificationsOpen && <div><strong>Notifications</strong>{notifications.length ? notifications.map((item) => <article key={String(item.id)}><span>{rowText(item, ["title"], "Booking update")}</span><p>{rowText(item, ["message"])}</p></article>) : <p>No notifications yet.</p>}</div>}</div>}
    </header>
  );
}

function CustomerFooter() {
  return (
    <footer className="customer-footer">
      <Brand light />
      <span>Need help? Our Venice team is ready to assist.</span>
      <a href="tel:+630000000000">Contact support</a>
    </footer>
  );
}

function AccountLayout({ active, children, description, title }: {
  active: "profile" | "history" | "messages" | "settings";
  children: ReactNode;
  description: string;
  title: string;
}) {
  const items = [
    ["profile", "/account/profile", "My Profile"],
    ["history", "/account/history", "Booking History"],
    ["messages", "/account/messages", "Messages"],
    ["settings", "/account/settings", "Account Settings"],
  ] as const;
  return (
    <main className="customer-page customer-account-page">
      <CustomerHeader />
      <section className="customer-account-heading">
        <span className="section-kicker">Customer account</span>
        <h1>{title}</h1>
        <p>{description}</p>
      </section>
      <section className="customer-account-shell">
        <aside className="customer-account-nav">
          <span>My Account</span>
          <nav aria-label="Account navigation">{items.map(([id, href, label]) => <a aria-current={active === id ? "page" : undefined} className={active === id ? "is-active" : ""} href={href} key={id}>{label}<Icon name="chevron" size={15} /></a>)}</nav>
        </aside>
        <div className="customer-account-main">{children}</div>
      </section>
      <CustomerFooter />
    </main>
  );
}

function CustomerMessagesPage() {
  return <AccountLayout active="messages" description="Send a message in Evently's interactive support chat demo." title="Messages">
    <CustomerMessagesPanel />
  </AccountLayout>;
}

type CustomerDataRow = Record<string, unknown>;

const rowValue = (row: CustomerDataRow, keys: string[]) => {
  const key = keys.find((candidate) => row[candidate] !== null && row[candidate] !== undefined && row[candidate] !== "");
  return key ? row[key] : null;
};
const rowText = (row: CustomerDataRow, keys: string[], fallback = "Not provided") => String(rowValue(row, keys) ?? fallback);
const rowNumber = (row: CustomerDataRow, keys: string[]) => Number(rowValue(row, keys) ?? 0);
const bookingPackageLabel = (row: CustomerDataRow, fallback?: CustomerDataRow | null) => {
  const packageName = rowValue(row, ["package_name", "_package_name"])
    ?? (fallback ? rowValue(fallback, ["package_name"]) : null)
    ?? rowValue(row, ["package_id"]);
  const packageVariant = rowValue(row, ["package_variant", "_package_variant"])
    ?? (fallback ? rowValue(fallback, ["package_variant"]) : null);
  const name = String(packageName ?? "Not provided");
  return packageVariant ? `${name} · ${String(packageVariant)}` : name;
};
const rowList = (row: CustomerDataRow, keys: string[]) => {
  const value = rowValue(row, keys);
  if (Array.isArray(value)) return value.map((item) => {
    if (item && typeof item === "object") {
      const record = item as Record<string, unknown>;
      return String(record.name ?? record.description ?? record.id ?? "Saved add-on");
    }
    return String(item);
  });
  if (value && typeof value === "object") return Object.entries(value as Record<string, unknown>).map(([key, item]) => `${key}: ${String(item)}`);
  return value ? [String(value)] : [];
};
const bookingReference = (row: CustomerDataRow) => rowText(row, ["reservation_code", "order_code", "booking_code", "code", "reference", "id"], "Unavailable");
const customerPaymentFor = (row: CustomerDataRow): CustomerDataRow | null => {
  const payment = rowValue(row, ["_latest_payment"]);
  return payment && typeof payment === "object" ? payment as CustomerDataRow : null;
};
const bookingStatus = (row: CustomerDataRow) => {
  const status = rowText(row, ["_reservation_status", "status", "order_status"], "Pending");
  if (status.toLowerCase() !== "pending") return status;
  const payment = customerPaymentFor(row);
  const verification = rowText(payment ?? {}, ["verification_status", "status"], "").toLowerCase();
  if (verification === "rejected") return "Payment Rejected / Resubmission Required";
  if (verification === "pending") return "Payment Submitted";
  if (verification === "verified" || ["partial", "paid"].includes(rowText(row, ["payment_status"], "").toLowerCase())) return "Pending Admin Approval";
  return "Pending Payment";
};
const paymentVerificationStatus = (row: CustomerDataRow) => {
  const payment = customerPaymentFor(row) ?? row;
  const status = rowText(payment, ["verification_status", "status"], "").toLowerCase();
  const isDemo = payment.demo_mode === true;
  if (status === "pending") return "Pending Verification";
  if (status === "verified") return isDemo ? "Demo Proof Accepted — No Funds Transferred" : "Verified";
  if (status === "rejected") return isDemo ? "Demo Proof Rejected — Resubmission Required" : "Rejected — Resubmission Required";
  return "No payment proof submitted";
};
const paymentStatus = (row: CustomerDataRow, booking: CustomerDataRow = row) => {
  const payment = customerPaymentFor(row) ?? row;
  const verification = rowText(payment, ["verification_status", "status"], "").toLowerCase();
  const storedStatus = rowText(booking, ["payment_status"], rowText(row, ["payment_status"], "unpaid")).toLowerCase();
  const total = rowNumber(booking, ["total_amount", "total", "amount"]);
  const storedAmount = rowNumber(booking, ["amount_paid", "paid_amount"]);
  const verifiedAmount = storedAmount > 0
    ? storedAmount
    : verification === "verified" && payment.demo_mode !== true
      ? rowNumber(payment, ["amount", "payment_amount"])
      : 0;
  if (total > 0 && verifiedAmount >= total) return "Fully Paid";
  if (storedStatus === "partial" || (total > 0 && verifiedAmount > 0)) {
    const deposit = requiredDeposit(booking);
    return deposit > 0 && verifiedAmount >= deposit
      ? "Deposit Verified · Partially Paid"
      : "Partially Paid";
  }
  if (verification === "pending") return "Pending Verification";
  if (verification === "rejected") return payment.demo_mode === true ? "Demo Proof Rejected — Resubmission Required" : "Rejected — Resubmission Required";
  if (verification === "verified") return payment.demo_mode === true ? "Demo Proof Accepted — No Funds Transferred" : "Deposit Verified";
  if (storedStatus === "paid") return "Payment Status Needs Review";
  if (storedStatus === "unpaid" || !storedStatus) return "Pending Payment";
  return storedStatus.replace(/[_-]+/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
};
const requiredDeposit = (row: CustomerDataRow) => rowNumber(row, ["deposit_amount", "_deposit_amount"]);
const remainingBalance = (row: CustomerDataRow) => {
  const stored = rowValue(row, ["remaining_balance", "_remaining_balance"]);
  return stored === null
    ? Math.max(0, rowNumber(row, ["total_amount", "total", "amount"]) - rowNumber(row, ["amount_paid", "paid_amount"]))
    : Math.max(0, Number(stored) || 0);
};
const bookingDate = (row: CustomerDataRow) => {
  const value = rowValue(row, ["reservation_date", "event_date", "date", "created_at"]);
  if (!value || Number.isNaN(Date.parse(String(value)))) return "Date not set";
  return new Date(String(value)).toLocaleDateString("en-PH", { month: "long", day: "numeric", year: "numeric" });
};
const bookingSchedule = (row: CustomerDataRow) => {
  const start = rowText(row, ["start_time"], "");
  const end = rowText(row, ["end_time"], "");
  if (!start || !end) return "Pending administrator assignment";
  const normalizedStart = start.slice(0, 5);
  const normalizedEnd = end.slice(0, 5);
  return `${normalizedStart}–${normalizedEnd}${normalizedEnd <= normalizedStart ? " · ends the following day" : ""}`;
};
const bookingTone = (status: string) => {
  const normalized = status.toLowerCase();
  if (normalized.includes("payment")) return "pending";
  if (normalized.includes("cancel") || normalized.includes("reject")) return "cancelled";
  if (normalized.includes("complete")) return "completed";
  if (normalized.includes("confirm")) return "confirmed";
  return "pending";
};

function CustomerLoadingState() {
  return <div className="customer-loading-state" aria-live="polite"><span /><span /><span /></div>;
}

function CustomerErrorState({ message, retry }: { message: string; retry?: () => void }) {
  return <div className="customer-empty-state" role="alert"><Icon name="close" size={22} /><h2>We couldn't load this information</h2><p>{message}</p>{retry && <button onClick={retry} type="button">Try Again</button>}</div>;
}

function CustomerAccountSettingsPage() {
  const { profile, session } = useAuth();
  const navigate = useNavigate();
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [newEmail, setNewEmail] = useState(profile?.email ?? session?.user.email ?? "");
  const [message, setMessage] = useState<{ text: string; type: "success" | "error" } | null>(null);
  const [saving, setSaving] = useState<"password" | "email" | "logout" | null>(null);

  const changePassword = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setMessage(null);
    if (password.length < 8) {
      setMessage({ text: "Your new password must contain at least 8 characters.", type: "error" });
      return;
    }
    if (password !== confirmPassword) {
      setMessage({ text: "Password confirmation does not match.", type: "error" });
      return;
    }
    setSaving("password");
    const { error } = await supabase.auth.updateUser({ password });
    setSaving(null);
    if (error) setMessage({ text: error.message, type: "error" });
    else {
      setPassword("");
      setConfirmPassword("");
      setMessage({ text: "Your password was updated successfully.", type: "success" });
    }
  };

  const changeEmail = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setMessage(null);
    if (!newEmail.includes("@")) {
      setMessage({ text: "Enter a valid email address.", type: "error" });
      return;
    }
    setSaving("email");
    const { error } = await supabase.auth.updateUser({ email: newEmail.trim() });
    setSaving(null);
    setMessage(error
      ? { text: error.message, type: "error" }
      : { text: "Check your new email address to confirm this change.", type: "success" });
  };

  const logout = async () => {
    setSaving("logout");
    await signOutUser();
    navigate("/", { replace: true });
  };

  return (
    <AccountLayout active="settings" description="Manage your account information and security." title="Account Settings">
      <section className="customer-account-card account-information-card">
        <div className="customer-card-heading"><div><span>Account information</span><h2>Your contact details</h2></div><a href="/account/profile">Edit Profile</a></div>
        <dl><div><dt>Email Address</dt><dd>{profile?.email || session?.user.email || "Not provided"}</dd></div><div><dt>Mobile Number</dt><dd>{profile?.mobile_number || "Not provided"}</dd></div><div><dt>Username</dt><dd>{profile?.username || "Not provided"}</dd></div></dl>
      </section>
      {message && <div className={`customer-inline-message customer-inline-message--${message.type}`} role="status">{message.text}</div>}
      <div className="customer-settings-grid">
        <form className="customer-account-card customer-security-form" onSubmit={changePassword}>
          <div className="customer-card-heading"><div><span>Security</span><h2>Change Password</h2></div></div>
          <label><span>New Password</span><input autoComplete="new-password" onChange={(event) => setPassword(event.target.value)} required type="password" value={password} /></label>
          <label><span>Confirm New Password</span><input autoComplete="new-password" onChange={(event) => setConfirmPassword(event.target.value)} required type="password" value={confirmPassword} /></label>
          <small>Use at least 8 characters.</small>
          <button disabled={saving !== null} type="submit">{saving === "password" ? "Updating…" : "Update Password"}</button>
        </form>
        <form className="customer-account-card customer-security-form" onSubmit={changeEmail}>
          <div className="customer-card-heading"><div><span>Authentication</span><h2>Update Email</h2></div></div>
          <label><span>New Email Address</span><input autoComplete="email" onChange={(event) => setNewEmail(event.target.value)} required type="email" value={newEmail} /></label>
          <p>Email changes are handled securely through Supabase Auth and may require confirmation.</p>
          <button disabled={saving !== null || newEmail === (session?.user.email ?? "")} type="submit">{saving === "email" ? "Sending…" : "Update Email"}</button>
        </form>
      </div>
      <section className="customer-account-card customer-logout-card"><div><span>Session</span><h2>Sign out of Evently</h2><p>You'll need to sign in again to view your private bookings and account details.</p></div><button disabled={saving !== null} onClick={logout} type="button">{saving === "logout" ? "Signing Out…" : "Logout"}</button></section>
    </AccountLayout>
  );
}

function CustomerProfilePage() {
  const { profile: authProfile, session } = useAuth();
  const [editing, setEditing] = useState(false);
  const [profile, setProfile] = useState<CustomerDataRow | null>(null);
  const [draft, setDraft] = useState({ fullName: "", username: "", mobile: "", avatarUrl: "" });
  const [error, setError] = useState("");
  const [toast, setToast] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  const loadProfile = useCallback(async () => {
    if (!session) return;
    setLoading(true);
    setError("");
    const { data, error: queryError } = await supabase.from("profiles").select("id,email,full_name,username,mobile_number,avatar_url,role,created_at").eq("id", session.user.id).single();
    setLoading(false);
    if (queryError) {
      setError(queryError.message);
      return;
    }
    const row = data as CustomerDataRow;
    setProfile(row);
    setDraft({
      fullName: rowText(row, ["full_name"], ""),
      username: rowText(row, ["username"], ""),
      mobile: rowText(row, ["mobile_number"], ""),
      avatarUrl: rowText(row, ["avatar_url"], ""),
    });
  }, [session]);

  useEffect(() => { void loadProfile(); }, [loadProfile]);

  const saveProfile = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const normalized = normalizePhilippineMobile(draft.mobile);
    if (!draft.fullName.trim() || !draft.username.trim()) {
      setError("Complete your full name and username.");
      return;
    }
    if (!normalized) {
      setError("Enter a valid Philippine mobile number, such as 0917 123 4567.");
      return;
    }
    if (!session) return;
    setSaving(true);
    setError("");
    const { error: updateError } = await supabase.from("profiles").update({
      full_name: draft.fullName.trim(),
      username: draft.username.trim(),
      mobile_number: normalized,
      avatar_url: draft.avatarUrl.trim() || null,
      updated_at: new Date().toISOString(),
    }).eq("id", session.user.id);
    setSaving(false);
    if (updateError) {
      setError(updateError.code === "23505" ? "That username is already in use." : updateError.message);
      return;
    }
    await loadProfile();
    setEditing(false);
    setToast("Profile updated successfully.");
  };

  if (loading) return <AccountLayout active="profile" description="Keep your personal details up to date." title="My Profile"><CustomerLoadingState /></AccountLayout>;
  if (!profile) return <AccountLayout active="profile" description="Keep your personal details up to date." title="My Profile"><CustomerErrorState message={error || "Your profile is unavailable."} retry={loadProfile} /></AccountLayout>;
  const fullName = rowText(profile, ["full_name"], "Evently Customer");
  const initials = fullName.split(" ").map((part) => part[0]).slice(0, 2).join("").toUpperCase();
  const joined = rowValue(profile, ["created_at"]);

  return (
    <AccountLayout active="profile" description="View and manage the information connected to your Evently account." title="My Profile">
      <section className="customer-profile-content">
        <aside className="profile-identity-card">
          <div className="profile-avatar">{draft.avatarUrl ? <img alt="" src={draft.avatarUrl} /> : initials || "EC"}</div>
          <h2>{fullName}</h2>
          <span>@{rowText(profile, ["username"], "customer")}</span>
          <small>{joined ? `Customer since ${new Date(String(joined)).toLocaleDateString("en-PH", { month: "long", year: "numeric" })}` : "Evently customer"}</small>
          <button onClick={() => setEditing(true)} type="button">Edit Profile <Icon name="arrow" size={16} /></button>
        </aside>
        <form className="profile-details-card" onSubmit={saveProfile}>
          <div className="profile-details-card__header"><div><span>Personal Information</span><h2>Profile Details</h2></div>{editing && <span>Editing</span>}</div>
          <div className="profile-form-grid">
            <label><span>Full Name</span><input disabled={!editing} onChange={(event) => setDraft({ ...draft, fullName: event.target.value })} value={draft.fullName} /></label>
            <label><span>Username</span><input disabled={!editing} onChange={(event) => setDraft({ ...draft, username: event.target.value })} value={draft.username} /></label>
            <label><span>Email Address</span><input disabled type="email" value={rowText(profile, ["email"], authProfile?.email || "")} /><small>Email changes are managed in Account Settings.</small></label>
            <label>
              <span>Mobile Number</span>
              <input disabled={!editing} onChange={(event) => { setDraft({ ...draft, mobile: event.target.value }); setError(""); }} placeholder="09XX XXX XXXX" value={draft.mobile} />
              <small>Used for automated booking notifications.</small>
            </label>
            <label><span>Profile Picture URL</span><input disabled={!editing} onChange={(event) => setDraft({ ...draft, avatarUrl: event.target.value })} placeholder="https://…" type="url" value={draft.avatarUrl} /><small>Only use an image you control. Storage upload is not configured.</small></label>
            <label><span>Account Role</span><input disabled value={rowText(profile, ["role"], "customer")} /></label>
            <label className="profile-created-field"><span>Date Joined</span><input disabled value={joined ? new Date(String(joined)).toLocaleDateString("en-PH", { month: "long", day: "numeric", year: "numeric" }) : "Not available"} /></label>
          </div>
          {error && <span className="account-settings-error" role="alert">{error}</span>}
          {editing && <div className="profile-form-actions"><button onClick={() => { setDraft({ fullName, username: rowText(profile, ["username"], ""), mobile: rowText(profile, ["mobile_number"], ""), avatarUrl: rowText(profile, ["avatar_url"], "") }); setEditing(false); setError(""); }} type="button">Cancel</button><button disabled={saving} type="submit">{saving ? "Saving…" : "Save Changes"}</button></div>}
        </form>
      </section>
      {toast && <FeedbackToast message={toast} onClose={() => setToast("")} />}
    </AccountLayout>
  );
}

function CustomerHistoryPage() {
  const { session } = useAuth();
  const navigate = useNavigate();
  const [filter, setFilter] = useState<"All" | "Pending" | "Confirmed" | "Completed" | "Cancelled">("All");
  const [search, setSearch] = useState("");
  const [records, setRecords] = useState<CustomerDataRow[]>([]);
  const [submittedReviews, setSubmittedReviews] = useState<Record<string, CustomerDataRow>>({});
  const [reviewDrafts, setReviewDrafts] = useState<Record<string, { rating: number; text: string }>>({});
  const [reviewFeedback, setReviewFeedback] = useState<Record<string, string>>({});
  const [reviewFeatureReady, setReviewFeatureReady] = useState(false);
  const [reviewSetupMessage, setReviewSetupMessage] = useState("");
  const [editingReviewIds, setEditingReviewIds] = useState<Record<string, boolean>>({});
  const [selected, setSelected] = useState<CustomerDataRow | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const loadHistory = useCallback(async (silent = false) => {
    if (!session) return;
    if (!silent) setLoading(true);
    setError("");
    const [reservations, orders, paymentResult] = await Promise.all([
      supabase.from("reservations").select("*").eq("customer_id", session.user.id),
      supabase.from("orders").select("*").eq("customer_id", session.user.id),
      supabase.from("payments").select("*").eq("customer_id", session.user.id).order("submitted_at", { ascending: false }),
    ]);
    if (!silent) setLoading(false);
    if (reservations.error) {
      setError(reservations.error.message);
      return;
    }
    const allOrders = (orders.data ?? []) as CustomerDataRow[];
    const allPayments = (paymentResult.data ?? []) as CustomerDataRow[];
    const latestPaymentFor = (record: CustomerDataRow) => allPayments
      .filter((payment) => String(payment.reservation_id ?? "") === String(record.id ?? "") || String(payment.order_id ?? "") === String(record.id ?? ""))
      .sort((left, right) => Date.parse(String(right.submitted_at ?? right.created_at ?? 0)) - Date.parse(String(left.submitted_at ?? left.created_at ?? 0)))[0] ?? null;
    const { data: reviewReady, error: readinessError } = await supabase.rpc("evently_review_features_ready");
    if (readinessError || reviewReady !== true) {
      setReviewFeatureReady(false);
      setReviewSetupMessage("Customer reviews are temporarily unavailable until the Supabase review migration is applied and verified.");
      setSubmittedReviews({});
    } else {
      setReviewFeatureReady(true);
      setReviewSetupMessage("");
      const reviewRows = await supabase.from("reviews")
        .select("id,reservation_id,rating,review_text,moderation_status,sentiment_label")
        .eq("customer_id", session.user.id);
      if (reviewRows.error) {
        setReviewFeatureReady(false);
        setReviewSetupMessage("Your review status could not be loaded. Refresh the page or contact support.");
      } else {
        setSubmittedReviews(Object.fromEntries(((reviewRows.data ?? []) as CustomerDataRow[]).map((review) => [String(review.reservation_id), review])));
      }
    }
    const reservationRows = (reservations.data ?? []).map((row) => {
      const linkedOrder = allOrders.find((order) => String(order.reservation_id) === String(row.id));
      const latestPayment = latestPaymentFor(row);
      return {
        ...row,
        _latest_payment: latestPayment,
        _record_type: "Reservation",
        _order_code: linkedOrder ? bookingReference(linkedOrder) : null,
        _order_status: linkedOrder ? rowText(linkedOrder, ["order_status", "status"], "Pending") : null,
      };
    });
    const reservationIds = new Set(reservationRows.map((row) => String(row.id)));
    const orderRows = orders.error ? [] : (orders.data ?? [])
      .filter((row) => !row.reservation_id || !reservationIds.has(String(row.reservation_id)))
      .map((row) => ({ ...row, _latest_payment: latestPaymentFor(row), _record_type: "Order" }));
    const nextRecords = [...reservationRows, ...orderRows].sort((a, b) => {
      const left = Date.parse(String(rowValue(a, ["reservation_date", "event_date", "created_at"]) ?? 0));
      const right = Date.parse(String(rowValue(b, ["reservation_date", "event_date", "created_at"]) ?? 0));
      return right - left;
    });
    setRecords(nextRecords);
    setSelected((current) => {
      if (!current) return null;
      return nextRecords.find((record) => String(record.id) === String(current.id)
        && rowText(record, ["_record_type"]) === rowText(current, ["_record_type"])) ?? current;
    });
  }, [session]);

  useEffect(() => {
    void loadHistory();
    const interval = window.setInterval(() => { void loadHistory(true); }, 30000);
    const refresh = () => { void loadHistory(true); };
    window.addEventListener(customerBookingsChangedEvent, refresh);
    return () => {
      window.clearInterval(interval);
      window.removeEventListener(customerBookingsChangedEvent, refresh);
    };
  }, [loadHistory]);
  useEffect(() => {
    if (!session) return;
    const refresh = () => { void loadHistory(true); };
    const channel = supabase.channel(`customer-history-${session.user.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "reservations", filter: `customer_id=eq.${session.user.id}` }, refresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "orders", filter: `customer_id=eq.${session.user.id}` }, refresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "payments", filter: `customer_id=eq.${session.user.id}` }, refresh)
      .subscribe();
    return () => { void supabase.removeChannel(channel); };
  }, [loadHistory, session]);
  const visible = records.filter((record) => {
    const tone = bookingTone(bookingStatus(record));
    const matchesFilter = filter === "All" || tone === filter.toLowerCase();
    return matchesFilter && bookingReference(record).toLowerCase().includes(search.trim().toLowerCase());
  });
  const selectedPayment = selected ? customerPaymentFor(selected) : null;
  const submitReview = async (reservationId: string) => {
    if (!reviewFeatureReady) {
      setReviewFeedback((current) => ({ ...current, [reservationId]: "Review features are not enabled yet. Please try again later." }));
      return;
    }
    const draft = reviewDrafts[reservationId] ?? { rating: 5, text: "" };
    const existingReview = submittedReviews[reservationId];
    const { data: reviewId, error: reviewError } = existingReview
      ? await supabase.rpc("evently_update_customer_review", {
          p_review_id: String(existingReview.id), p_rating: draft.rating, p_review_text: draft.text,
        })
      : await supabase.rpc("evently_submit_customer_review", {
          p_reservation_id: reservationId, p_rating: draft.rating, p_review_text: draft.text,
        });
    if (reviewError) {
      setReviewFeedback((current) => ({ ...current, [reservationId]: reviewError.message }));
      return;
    }
    setEditingReviewIds((current) => ({ ...current, [reservationId]: false }));
    setReviewFeedback((current) => ({ ...current, [reservationId]: "Review saved. Sentiment analysis is pending." }));
    await loadHistory(true);

    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session?.access_token) return;
    try {
      const response = await fetch(`${eventlyFunctionBaseUrl}/reviews/analyze`, {
        method: "POST",
        headers: { Authorization: `Bearer ${sessionData.session.access_token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ review_id: reviewId }),
      });
      const result = await response.json().catch(() => ({}));
      if (response.ok) {
        setReviewFeedback((current) => ({ ...current, [reservationId]: `Review saved for moderation. Sentiment analysis completed: ${result.sentiment}.` }));
      } else {
        setReviewFeedback((current) => ({ ...current, [reservationId]: `Review saved for moderation. Sentiment analysis remains pending: ${String(result.error ?? "service unavailable")}` }));
      }
    } catch {
      setReviewFeedback((current) => ({ ...current, [reservationId]: "Review saved for moderation. Sentiment analysis is pending and can be retried later." }));
    }
    await loadHistory(true);
  };
  const editReview = (reservationId: string) => {
    const review = submittedReviews[reservationId];
    if (!review) return;
    setReviewDrafts((current) => ({
      ...current,
      [reservationId]: { rating: Number(review.rating ?? 5), text: String(review.review_text ?? "") },
    }));
    setEditingReviewIds((current) => ({ ...current, [reservationId]: true }));
    setReviewFeedback((current) => ({ ...current, [reservationId]: "Editing will unpublish this review until moderation is completed again." }));
  };

  return (
    <AccountLayout active="history" description="View your reservations, track their progress, and review your past experiences." title="My Booking History">
      <section className="customer-history-content">
        <div className="history-toolbar">
         <div>{(["All", "Pending", "Confirmed", "Completed", "Cancelled"] as const).map((item) => <button className={filter === item ? "history-filter-active" : ""} key={item} onClick={() => setFilter(item)} type="button">{item === "All" ? "All Bookings" : item}</button>)}</div>
          <label><span>Search</span><input onChange={(event) => setSearch(event.target.value)} placeholder="Search reference…" value={search} /></label>
        </div>
        {reviewSetupMessage && <p className="customer-review-setup-message" role="status">{reviewSetupMessage}</p>}
        {loading ? <CustomerLoadingState /> : error ? <CustomerErrorState message={error} retry={loadHistory} /> : !visible.length ? <div className="customer-empty-state"><Icon name="calendar" size={24} /><h2>No bookings found</h2><p>{records.length ? "Try a different status or reference search." : "Your reservations will appear here after a booking is saved."}</p></div> : <div className="history-card-grid">{visible.map((record) => {
          const status = bookingStatus(record);
          const reference = bookingReference(record);
          return (
            <article className="customer-history-card" key={`${rowText(record, ["_record_type"])}-${rowText(record, ["id"], reference)}`}>
              <div className="customer-history-card__top"><span>{rowText(record, ["_record_type"])}</span><strong>{reference}</strong><i className={`history-status history-status--${bookingTone(status)}`}>{status}</i></div>
              <h2>{rowText(record, ["service", "service_type", "service_category"])}</h2><p>{bookingPackageLabel(record)}</p>
              <dl><div><dt>Reservation Date</dt><dd>{bookingDate(record)}</dd></div><div><dt>Schedule</dt><dd>{bookingSchedule(record)}</dd></div><div><dt>Guests</dt><dd>{rowText(record, ["guest_count", "guests", "number_of_guests"], "—")}</dd></div>{Boolean(rowValue(record, ["resource_name", "resource_key"])) && <div><dt>Venue / Resource</dt><dd>{rowText(record, ["resource_name", "resource_key"])}</dd></div>}<div><dt>Total Booking Cost</dt><dd>{formatPhp(rowNumber(record, ["total_amount", "total", "amount"]))}</dd></div><div><dt>Required Deposit</dt><dd>{formatPhp(requiredDeposit(record))}</dd></div><div><dt>Verified Amount Paid</dt><dd>{formatPhp(rowNumber(record, ["amount_paid", "paid_amount"]))}</dd></div><div><dt>Remaining Balance</dt><dd>{formatPhp(remainingBalance(record))}</dd></div><div><dt>Payment Status</dt><dd>{paymentStatus(record)}</dd></div>{Boolean(rowValue(record, ["_order_status"])) && <div><dt>Order Status</dt><dd>{rowText(record, ["_order_status"])}</dd></div>}</dl>
               <div className="history-card-actions"><button onClick={() => setSelected(record)} type="button">View Details</button><button onClick={() => navigate(`/track-order?ref=${encodeURIComponent(reference)}`)} type="button">Track Booking</button>{Boolean(rowValue(record, ["_order_code"])) && <button onClick={() => navigate(`/order?ref=${encodeURIComponent(rowText(record, ["_order_code"]))}`)} type="button">Payment Details</button>}</div>
                {rowText(record, ["_record_type"]) === "Reservation" && status.toLowerCase() === "completed" && (submittedReviews[String(record.id)] && !editingReviewIds[String(record.id)] ? <div className="customer-review-state"><strong>Your review: {rowText(submittedReviews[String(record.id)], ["moderation_status"], "pending")}</strong><p>{rowText(submittedReviews[String(record.id)], ["review_text", "comment"])}</p><small>Sentiment: {rowText(submittedReviews[String(record.id)], ["sentiment_label"], "Pending analysis")}</small><button disabled={!reviewFeatureReady} onClick={() => editReview(String(record.id))} type="button">Edit and resubmit</button>{reviewFeedback[String(record.id)] && <p role="status">{reviewFeedback[String(record.id)]}</p>}</div> : reviewFeatureReady && <form className="customer-review-form" onSubmit={(event) => { event.preventDefault(); void submitReview(String(record.id)); }}><strong>{submittedReviews[String(record.id)] ? "Edit and resubmit your review" : "Share your experience"}</strong><label>Rating<select value={reviewDrafts[String(record.id)]?.rating ?? 5} onChange={(event) => setReviewDrafts((current) => ({ ...current, [String(record.id)]: { ...(current[String(record.id)] ?? { text: "", rating: 5 }), rating: Number(event.target.value) } }))}>{[5,4,3,2,1].map((rating) => <option key={rating} value={rating}>{rating} stars</option>)}</select></label><label>Your review<textarea minLength={10} maxLength={3000} required value={reviewDrafts[String(record.id)]?.text ?? ""} onChange={(event) => setReviewDrafts((current) => ({ ...current, [String(record.id)]: { ...(current[String(record.id)] ?? { text: "", rating: 5 }), text: event.target.value } }))} /></label><button type="submit">{submittedReviews[String(record.id)] ? "Save and resubmit" : "Submit review"}</button>{reviewFeedback[String(record.id)] && <p role="status">{reviewFeedback[String(record.id)]}</p>}</form>)}
            </article>
          );
        })}</div>}
      </section>
      {selected && (
        <><button className="detail-panel-overlay" aria-label="Close transaction details" onClick={() => setSelected(null)} type="button" /><aside className="reservation-detail-panel customer-history-detail">
          <div className="detail-panel__header"><div><span>{rowText(selected, ["_record_type"])} details</span><h2>{bookingReference(selected)}</h2></div><button aria-label="Close details" onClick={() => setSelected(null)} type="button"><Icon name="close" /></button></div>
          <div className="detail-status-row"><span className={`history-status history-status--${bookingTone(bookingStatus(selected))}`}>{bookingStatus(selected)}</span><span>{paymentStatus(selected)}</span></div>
          <h3 className="customer-detail-section-title">Booking information</h3>
          <dl className="detail-panel__facts"><div><dt>Service</dt><dd>{rowText(selected, ["service", "service_type"])}</dd></div><div><dt>Package / Tour Slot</dt><dd>{bookingPackageLabel(selected)}</dd></div><div><dt>Event Date</dt><dd>{bookingDate(selected)}</dd></div><div><dt>Schedule</dt><dd>{bookingSchedule(selected)}</dd></div><div><dt>Guests</dt><dd>{rowText(selected, ["guest_count", "guests"], "—")}</dd></div>{Boolean(rowValue(selected, ["resource_name", "resource_key"])) && <div><dt>Venue / Resource</dt><dd>{rowText(selected, ["resource_name", "resource_key"])}</dd></div>}<div><dt>Customer</dt><dd>{rowText(selected, ["customer_name", "full_name"], "Your account")}</dd></div><div><dt>Payment Status</dt><dd>{paymentStatus(selected)}</dd></div></dl>
          {selectedPayment && <div className="detail-panel__section"><span>Payment submission</span><dl className="detail-panel__facts"><div><dt>Method</dt><dd>{rowText(selectedPayment, ["method", "payment_method"])}</dd></div><div><dt>Reference</dt><dd>{rowText(selectedPayment, ["reference_number"], "Not recorded")}</dd></div><div><dt>Submitted amount</dt><dd>{formatPhp(rowNumber(selectedPayment, ["amount", "payment_amount"]))}</dd></div><div><dt>Submitted</dt><dd>{rowText(selectedPayment, ["submitted_at", "created_at"], "Not recorded")}</dd></div><div><dt>Receipt upload</dt><dd>{rowValue(selectedPayment, ["proof_url"]) ? "Private receipt received" : "No receipt attached"}</dd></div><div><dt>Administrator review</dt><dd>{paymentVerificationStatus(selectedPayment)}</dd></div>{Boolean(rowValue(selectedPayment, ["rejection_reason", "review_notes"])) && <div><dt>Review note</dt><dd>{rowText(selectedPayment, ["rejection_reason", "review_notes"])}</dd></div>}</dl>{selectedPayment.demo_mode === true && <p>Demo Payment — No Actual Money Transfer. This record is for demonstration and review only.</p>}{rowText(selectedPayment, ["verification_status", "status"], "").toLowerCase() === "rejected" && Boolean(rowValue(selected, ["_order_code"])) && <button onClick={() => navigate(`/order?ref=${encodeURIComponent(rowText(selected, ["_order_code"]))}`)} type="button">Resubmit payment proof</button>}</div>}
          {rowList(selected, ["menu_items", "selected_menu", "menu"]).length > 0 && <div className="detail-panel__section"><span>Catering Menu</span><p>{rowList(selected, ["menu_items", "selected_menu", "menu"]).join(" · ")}</p></div>}
          {rowList(selected, ["addons", "selected_addons"]).length > 0 && <div className="detail-panel__section"><span>Selected Add-ons</span><p>{rowList(selected, ["addons", "selected_addons"]).join(" · ")}</p></div>}
          {Boolean(rowValue(selected, ["special_requests", "requests", "notes"])) && <div className="detail-panel__section"><span>Special Requests</span><p>{rowText(selected, ["special_requests", "requests", "notes"])}</p></div>}
          <div className="history-payment-summary"><div><span>Total Booking Cost</span><strong>{formatPhp(rowNumber(selected, ["total_amount", "total", "amount"]))}</strong></div><div><span>Required Deposit</span><strong>{formatPhp(requiredDeposit(selected))}</strong></div><div><span>Verified Amount Paid</span><strong>{formatPhp(rowNumber(selected, ["amount_paid", "paid_amount"]))}</strong></div><div><span>Remaining Balance</span><strong>{formatPhp(remainingBalance(selected))}</strong></div></div>
        </aside></>
      )}
    </AccountLayout>
  );
}

type CustomerPaymentMethod = "gcash" | "maya" | "bank_transfer" | "other" | "cash";
type CustomerPaymentAccount = {
  id: string;
  method: CustomerPaymentMethod;
  display_name: string;
  account_holder: string;
  bank_name: string;
  account_number: string;
  mobile_wallet_number: string;
  instructions: string;
  qr_code_url: string;
  is_active: boolean;
};

const customerPaymentMethodLabels: Record<CustomerPaymentMethod, string> = {
  gcash: "GCash",
  maya: "Maya",
  bank_transfer: "Bank Transfer",
  other: "Other",
  cash: "Cash",
};

function OrderPage() {
  const { session } = useAuth();
  const navigate = useNavigate();
  const reference = new URLSearchParams(window.location.search).get("ref")?.trim() ?? "";
  const [order, setOrder] = useState<CustomerDataRow | null>(null);
  const [reservation, setReservation] = useState<CustomerDataRow | null>(null);
  const [payments, setPayments] = useState<CustomerDataRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [paymentMethod, setPaymentMethod] = useState<CustomerPaymentMethod>("gcash");
  const [paymentReference, setPaymentReference] = useState("");
  const [paymentProof, setPaymentProof] = useState<File | null>(null);
  const paymentProofInput = useRef<HTMLInputElement | null>(null);
  const [paymentProofPreview, setPaymentProofPreview] = useState("");
  const [paymentAmount, setPaymentAmount] = useState("");
  const [pendingPaymentProofPath, setPendingPaymentProofPath] = useState("");
  const [paymentMessage, setPaymentMessage] = useState("");
  const [paymentSubmitting, setPaymentSubmitting] = useState(false);
  const [paymentAccounts, setPaymentAccounts] = useState<CustomerPaymentAccount[]>([]);
  const [demoPaymentMode, setDemoPaymentMode] = useState(true);
  const [paymentOptionsError, setPaymentOptionsError] = useState("");

  useEffect(() => {
    if (!paymentProof) { setPaymentProofPreview(""); return; }
    const previewUrl = URL.createObjectURL(paymentProof);
    setPaymentProofPreview(previewUrl);
    return () => URL.revokeObjectURL(previewUrl);
  }, [paymentProof]);

  const loadOrder = useCallback(async (silent = false) => {
    if (!session) return;
    if (!silent) setLoading(true);
    setError("");
    const orderResult = await supabase.from("orders").select("*").eq("customer_id", session.user.id);
    if (!silent) setLoading(false);
    if (orderResult.error) { setError(orderResult.error.message); return; }
    const owned = (orderResult.data ?? []) as CustomerDataRow[];
    const found = reference
      ? owned.find((row) => bookingReference(row).toLowerCase() === reference.toLowerCase()) ?? null
      : owned.sort((a, b) => Date.parse(String(rowValue(b, ["created_at"]) ?? 0)) - Date.parse(String(rowValue(a, ["created_at"]) ?? 0)))[0] ?? null;
    setOrder(found);
    setReservation(null);
    if (found) {
      const id = String(rowValue(found, ["id"]) ?? "");
      const reservationId = String(rowValue(found, ["reservation_id"]) ?? "");
      const [paymentResult, reservationResult] = await Promise.all([
        supabase.from("payments").select("*").eq("order_id", id).order("created_at", { ascending: false }),
        reservationId
          ? supabase.from("reservations").select("*").eq("id", reservationId).eq("customer_id", session.user.id).maybeSingle()
          : Promise.resolve({ data: null, error: null }),
      ]);
      if (!paymentResult.error) setPayments((paymentResult.data ?? []) as CustomerDataRow[]);
      if (!reservationResult.error) setReservation((reservationResult.data as CustomerDataRow | null) ?? null);
    }
  }, [reference, session]);
  useEffect(() => {
    void loadOrder();
    const interval = window.setInterval(() => { void loadOrder(true); }, 30000);
    return () => window.clearInterval(interval);
  }, [loadOrder]);
  useEffect(() => {
    if (!session) return;
    const refresh = () => { void loadOrder(true); };
    window.addEventListener(customerBookingsChangedEvent, refresh);
    const channel = supabase.channel(`customer-order-payment-status-${session.user.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "orders", filter: `customer_id=eq.${session.user.id}` }, refresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "reservations", filter: `customer_id=eq.${session.user.id}` }, refresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "payments", filter: `customer_id=eq.${session.user.id}` }, refresh)
      .subscribe();
    return () => {
      window.removeEventListener(customerBookingsChangedEvent, refresh);
      void supabase.removeChannel(channel);
    };
  }, [loadOrder, session]);
  useEffect(() => {
    supabase.rpc("evently_customer_payment_options").then(({ data, error: optionsError }) => {
      if (optionsError) { setPaymentOptionsError(optionsError.message); return; }
      if (!data || typeof data !== "object") return;
       const options = data as { accounts?: unknown; configured?: boolean; demo_mode?: boolean; legacy_instructions?: Record<string, string> };
       setPaymentAccounts(Array.isArray(options.accounts) ? options.accounts as CustomerPaymentAccount[] : []);
        setDemoPaymentMode(options.demo_mode !== false);
    });
  }, []);

  const total = order ? rowNumber(order, ["total_amount", "total", "amount"]) : 0;
  const verifiedPaid = payments.filter((payment) => payment.demo_mode !== true && ["verified", "paid"].includes(rowText(payment, ["verification_status", "payment_status", "status"], "").toLowerCase())).reduce((sum, payment) => sum + rowNumber(payment, ["amount", "payment_amount"]), 0);
  const storedPaid = order ? rowNumber(order, ["amount_paid", "paid_amount"]) : 0;
  const amountPaid = Math.max(verifiedPaid, storedPaid);
  const depositAmount = reservation ? requiredDeposit(reservation) : 0;
  const menu = order ? rowList(order, ["menu_items", "selected_menu", "menu"]) : [];
  const addons = order ? rowList(order, ["addons", "selected_addons"]) : [];
  const outstandingBalance = reservation ? remainingBalance(reservation) : Math.max(0, total - amountPaid);
  const amountDueNow = amountPaid > 0
    ? outstandingBalance
    : Math.min(outstandingBalance, depositAmount > 0 ? depositAmount : total);
  const activePaymentAccounts = paymentAccounts.filter((account) => account.is_active
    && ["gcash", "maya", "bank_transfer"].includes(account.method)
    && Boolean(account.display_name?.trim() && account.instructions?.trim() && account.account_holder?.trim())
    && (account.method === "bank_transfer"
      ? Boolean(account.bank_name?.trim() && account.account_number?.trim())
      : Boolean(account.mobile_wallet_number?.trim())));
  const availablePaymentMethods: CustomerPaymentMethod[] = Array.from(new Set(activePaymentAccounts.map((account) => account.method)));
  const availablePaymentMethodKey = availablePaymentMethods.join("|");
  const selectedPaymentAccount = activePaymentAccounts.find((account) => account.method === paymentMethod) ?? null;
  const selectedPaymentInstructions = selectedPaymentAccount?.instructions ?? "";
  const latestPayment = payments[0] ?? null;
  const latestPaymentStatus = rowText(latestPayment ?? {}, ["verification_status", "status"], "").toLowerCase();
  const paymentAwaitingReview = payments.some((payment) => rowText(payment, ["verification_status", "status"], "").toLowerCase() === "pending");
  const demoProofAccepted = payments.some((payment) => payment.demo_mode === true && rowText(payment, ["verification_status", "status"], "").toLowerCase() === "verified");
  useEffect(() => {
    if (availablePaymentMethods.length && !availablePaymentMethods.includes(paymentMethod)) setPaymentMethod(availablePaymentMethods[0]);
  }, [availablePaymentMethodKey, paymentMethod]);
  const submitPayment = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!session || !order || paymentSubmitting) return;
    setPaymentMessage("");
    const amount = Number(paymentAmount);
    if (!Number.isFinite(amount) || amount <= 0 || amount > outstandingBalance) {
      setPaymentMessage("Enter the amount you actually paid. It must be greater than zero and no more than the saved booking balance.");
      return;
    }
    if (paymentAwaitingReview) {
      setPaymentMessage("A payment submission is already awaiting administrator review. Please wait for its decision.");
      return;
    }
    if (!paymentReference.trim() || !paymentProof) {
      setPaymentMessage("A transaction reference and proof of payment are required.");
      return;
    }
    if (!availablePaymentMethods.includes(paymentMethod) || !selectedPaymentAccount || !selectedPaymentInstructions.trim()) {
      setPaymentMessage("This payment method is not configured. Contact Venice before submitting payment.");
      return;
    }
    if (!["image/jpeg", "image/png", "image/webp"].includes(paymentProof.type) || paymentProof.size > 10 * 1024 * 1024) {
      setPaymentMessage("Proof must be a JPG, PNG, or WebP image no larger than 10 MB.");
      return;
    }
    setPaymentSubmitting(true);
    try {
      let proofPath = pendingPaymentProofPath;
      if (!proofPath && paymentProof) {
        const extension = paymentProof.type === "image/jpeg" ? "jpg" : paymentProof.type === "image/png" ? "png" : "webp";
        proofPath = `${session.user.id}/${crypto.randomUUID()}.${extension}`;
        const upload = await supabase.storage.from("payment-proofs").upload(proofPath, paymentProof, {
          contentType: paymentProof.type,
          upsert: false,
        });
        if (upload.error) throw upload.error;
        setPendingPaymentProofPath(proofPath);
      }
      const reservationId = String(rowValue(order, ["reservation_id"]) ?? "");
      if (!reservationId) throw new Error("This order is not linked to a reservation.");
      const { error: submitError } = await supabase.rpc("evently_submit_payment_proof", {
        p_reservation_id: reservationId,
        p_amount: amount,
        p_method: paymentMethod,
        p_reference_number: paymentReference.trim(),
        p_proof_path: proofPath,
      });
      if (submitError) throw submitError;
        setPaymentMessage(demoPaymentMode ? "Demo payment submitted for administrator verification. No actual money transfer is represented." : "Payment proof submitted for administrator verification.");
        setPaymentReference("");
        setPaymentProof(null);
        setPaymentAmount("");
        setPendingPaymentProofPath("");
        if (paymentProofInput.current) paymentProofInput.current.value = "";
        await loadOrder();
     } catch (paymentError) {
       setPaymentMessage(paymentError instanceof Error ? paymentError.message : "Payment submission failed.");
    } finally {
      setPaymentSubmitting(false);
    }
  };

  return (
    <main className="customer-page customer-record-page">
      <CustomerHeader />
       <section className="customer-record-heading"><span className="section-kicker">Customer order</span><h1>Order Details</h1><p>Review your saved order, payment progress, menu, and event notes.</p></section>
      {loading ? <section className="customer-record-container"><CustomerLoadingState /></section> : error ? <section className="customer-record-container"><CustomerErrorState message={error} retry={loadOrder} /></section> : !order ? <section className="customer-record-container"><div className="customer-empty-state"><Icon name="calendar" size={24} /><h2>{reference ? "Order not found" : "No orders yet"}</h2><p>{reference ? "This order is unavailable or does not belong to your account." : "Your saved orders will appear here."}</p><a href="/account/history">View Booking History</a></div></section> : <section className="order-content">
        <div className="order-card">
           <div className="order-card__header"><div><span>Order Reference</span><strong>{bookingReference(order)}</strong></div><button onClick={() => navigate(`/track-order?ref=${encodeURIComponent(bookingReference(reservation ?? order))}`)} type="button">Track Booking <Icon name="arrow" size={17} /></button></div>
          <div className="order-overview"><div><span>Service</span><strong>{rowText(order, ["service", "service_type"])}</strong></div><div><span>Package</span><strong>{bookingPackageLabel(order, reservation)}</strong></div><div><span>Guests</span><strong>{rowText(order, ["guest_count", "guests"], "—")}</strong></div><div><span>Event Date</span><strong>{bookingDate(order)}</strong></div></div>
          <div className="order-sections">
            <article><div className="order-section__title"><span>01</span><h2>Catering Menu</h2></div>{menu.length ? <ul className="menu-list">{menu.map((item) => <li key={item}><i />{item}</li>)}</ul> : <p className="order-empty-copy">No catering menu stored for this order.</p>}</article>
            <article><div className="order-section__title"><span>02</span><h2>Add-ons</h2></div>{addons.length ? <ul className="menu-list">{addons.map((item) => <li key={item}><i />{item}</li>)}</ul> : <p className="order-empty-copy">No add-ons stored for this order.</p>}</article>
            <article className="order-section--wide"><div className="order-section__title"><span>03</span><h2>Special Requests</h2></div><p className="special-request">{rowText(order, ["special_requests", "requests", "notes"], "No special requests were recorded.")}</p></article>
          </div>
        </div>
          <aside className="payment-card"><span className="section-kicker">Payment summary</span><dl><div><dt>Total Booking Cost</dt><dd>{formatPhp(total)}</dd></div><div><dt>Required Deposit</dt><dd>{formatPhp(depositAmount)}</dd></div><div className="payment-card__paid"><dt>Verified Amount Paid</dt><dd>{formatPhp(amountPaid)}</dd></div><div className="payment-card__balance"><dt>Remaining Balance</dt><dd>{formatPhp(outstandingBalance)}</dd></div></dl><div className="payment-method"><span>Payment Method</span><strong>{rowText(latestPayment ?? order, ["payment_method", "method"], "Not recorded")}</strong></div><div className="payment-status"><span>Payment Status</span><strong>{paymentStatus(latestPayment ?? order, reservation ?? order)}</strong></div><div className="payment-status"><span>Payment Verification</span><strong>{paymentVerificationStatus(latestPayment ?? order)}</strong></div><div className="payment-status"><span>Booking Status</span><strong>{bookingStatus({ ...order, _reservation_status: reservation?.status, _latest_payment: latestPayment })}</strong></div><div className="payment-status"><span>Order Status</span><strong>{rowText(order, ["order_status", "status"], "Not provided")}</strong></div>
           {latestPayment && <div className="payment-status"><span>Payment reference</span><strong>{rowText(latestPayment, ["reference_number"], "Not recorded")}</strong></div>}
           {latestPayment && <div className="payment-status"><span>Receipt upload</span><strong>{rowValue(latestPayment, ["proof_url"]) ? "Private receipt received" : "No receipt attached"}</strong></div>}
            {latestPayment && Boolean(rowValue(latestPayment, ["rejection_reason", "review_notes"])) && <p className="booking-payment-message is-error"><strong>Admin review:</strong> {rowText(latestPayment, ["rejection_reason", "review_notes"])}</p>}
           {latestPayment?.demo_mode === true && <div className="booking-demo-payment-note"><strong>Demo Payment — No Actual Money Transfer</strong><span>This sample proof does not represent real funds.</span></div>}
           {paymentAwaitingReview && <p className="booking-payment-message">A payment proof is awaiting administrator review. Please wait for the decision before submitting another proof.</p>}
           {demoProofAccepted && <p className="booking-payment-message">Your demo proof was accepted for booking review. No funds were recorded, and no additional demo proof is needed for this booking review.</p>}
           {outstandingBalance > 0 && !paymentAwaitingReview && !demoProofAccepted && <form className="payment-submission-form" onSubmit={submitPayment}>
             <h2>{latestPaymentStatus === "rejected" ? "Resubmit Payment Proof" : "Submit a Payment"}</h2>
             {demoPaymentMode && <div className="booking-demo-payment-note"><strong>Demo Payment — No Actual Money Transfer</strong><span>Use sample transaction data only. No processor is connected.</span></div>}
              <label><span>Payment method</span><select disabled={!availablePaymentMethods.length} value={paymentMethod} onChange={(event) => setPaymentMethod(event.target.value as CustomerPaymentMethod)}>{availablePaymentMethods.map((method) => <option key={method} value={method}>{customerPaymentMethodLabels[method]}</option>)}</select></label>
              {paymentOptionsError && <p className="booking-payment-message is-error" role="alert">Payment destinations could not be loaded: {paymentOptionsError}</p>}
              {!availablePaymentMethods.length && <p role="status">No active, correctly configured payment destinations are currently available. Contact Venice before sending funds.</p>}
             {selectedPaymentAccount && <div className="customer-payment-destination"><strong>{selectedPaymentAccount.display_name}</strong>{selectedPaymentAccount.account_holder && <span>Account holder: {selectedPaymentAccount.account_holder}</span>}{selectedPaymentAccount.bank_name && <span>Bank: {selectedPaymentAccount.bank_name}</span>}{(selectedPaymentAccount.mobile_wallet_number || selectedPaymentAccount.account_number) && <span>Send to: {selectedPaymentAccount.mobile_wallet_number || selectedPaymentAccount.account_number}</span>}{selectedPaymentAccount.qr_code_url && <img alt={`${selectedPaymentAccount.display_name} payment QR code`} src={selectedPaymentAccount.qr_code_url} />}<p>{selectedPaymentInstructions}</p></div>}
             {!selectedPaymentAccount && selectedPaymentInstructions && <p>{selectedPaymentInstructions}</p>}
               <div className="payment-card__balance"><span>Total booking price</span><strong>{formatPhp(total)}</strong></div>
               <div className="payment-card__balance"><span>Suggested amount due</span><strong>{formatPhp(amountDueNow)}</strong></div>
               <label><span>Actual amount paid (PHP)</span><input max={outstandingBalance} min="0.01" onChange={(event) => setPaymentAmount(event.target.value)} required step="0.01" type="number" value={paymentAmount} /><small>Enter the amount you actually transferred. It may differ from the suggested amount.</small></label>
             <label><span>Transaction reference</span><input maxLength={160} onChange={(event) => setPaymentReference(event.target.value)} required value={paymentReference} /></label>
             <label><span>Proof of payment (JPG, PNG, or WebP · max 10 MB)</span><input accept=".jpg,.jpeg,.png,.webp,image/jpeg,image/png,image/webp" ref={paymentProofInput} onChange={(event) => {
               const file = event.target.files?.[0] ?? null;
               if (file && (!["image/jpeg", "image/png", "image/webp"].includes(file.type) || file.size > 10 * 1024 * 1024)) {
                 setPaymentMessage("Proof must be a JPG, PNG, or WebP image no larger than 10 MB.");
                 event.target.value = "";
                 setPaymentProof(null);
                 return;
               }
                setPaymentMessage("");
                setPendingPaymentProofPath("");
                setPaymentProof(file);
             }} required={!paymentProof} type="file" /></label>
              {paymentProof && <div className="booking-receipt-preview"><img alt="Receipt screenshot preview" src={paymentProofPreview} /><div><strong>{paymentProof.name}</strong><span>{(paymentProof.size / (1024 * 1024)).toFixed(2)} MB</span><div><button onClick={() => paymentProofInput.current?.click()} type="button">Replace image</button><button onClick={() => { setPaymentProof(null); setPendingPaymentProofPath(""); if (paymentProofInput.current) paymentProofInput.current.value = ""; }} type="button">Remove image</button></div></div></div>}
              <button disabled={paymentSubmitting || !availablePaymentMethods.length || Boolean(paymentOptionsError)} type="submit">{paymentSubmitting ? "Submitting…" : "Submit for Verification"}</button>
            {paymentMessage && <span role="status">{paymentMessage}</span>}
           </form>}
        </aside>
      </section>}
      <CustomerFooter />
    </main>
  );
}

const reservationTrackingStages = ["Pending", "Confirmed", "Completed"];
const orderTrackingStages = ["Pending", "Confirmed", "Preparing", "Ready", "Completed"];

function TrackOrderPage() {
  const { session } = useAuth();
  const [reference, setReference] = useState(() => new URLSearchParams(window.location.search).get("ref") ?? "");
  const [searched, setSearched] = useState(false);
  const [trackingState, setTrackingState] = useState<AsyncState>("default");
  const [tracked, setTracked] = useState<CustomerDataRow | null>(null);
  const [payments, setPayments] = useState<CustomerDataRow[]>([]);
  const [lookupError, setLookupError] = useState("");

  const findBooking = useCallback(async (value: string, silent = false) => {
    if (!session || !value.trim()) return;
    if (!silent) {
      setTrackingState("loading");
      setSearched(false);
      setTracked(null);
      setPayments([]);
    }
    setLookupError("");
    const [reservations, orders] = await Promise.all([
      supabase.from("reservations").select("*").eq("customer_id", session.user.id),
      supabase.from("orders").select("*").eq("customer_id", session.user.id),
    ]);
    if (reservations.error) {
      setLookupError(reservations.error.message); setTrackingState("error"); setSearched(true); return;
    }
    const normalized = value.trim().toLowerCase();
    const reservation = ((reservations.data ?? []) as CustomerDataRow[]).find((row) => bookingReference(row).toLowerCase() === normalized);
    const order = orders.error ? null : ((orders.data ?? []) as CustomerDataRow[]).find((row) => bookingReference(row).toLowerCase() === normalized);
    const linkedOrder = reservation && !orders.error
      ? ((orders.data ?? []) as CustomerDataRow[]).find((row) => String(row.reservation_id) === String(reservation.id))
      : null;
    const linkedReservation = order
      ? ((reservations.data ?? []) as CustomerDataRow[]).find((row) => String(row.id) === String(order.reservation_id))
      : reservation;
      const match = order
        ? {
        ...order,
        _deposit_amount: linkedReservation ? requiredDeposit(linkedReservation) : 0,
        _package_name: linkedReservation ? rowValue(linkedReservation, ["package_name"]) : null,
        _package_variant: linkedReservation ? rowValue(linkedReservation, ["package_variant"]) : null,
        _reservation_status: linkedReservation ? rowValue(linkedReservation, ["status"]) : null,
        _record_type: "Order",
        _remaining_balance: linkedReservation ? remainingBalance(linkedReservation) : rowValue(order, ["remaining_balance"]),
      }
      : reservation
        ? { ...reservation, _record_type: "Reservation", _order_status: linkedOrder ? rowText(linkedOrder, ["order_status", "status"], "Pending") : null }
        : null;
    if (match) {
      const id = String(rowValue(match, ["id"]) ?? "");
      const relationship = order ? "order_id" : "reservation_id";
      const paymentResult = await supabase.from("payments").select("*").eq(relationship, id);
      const paymentRows = paymentResult.error ? [] : (paymentResult.data ?? []) as CustomerDataRow[];
      paymentRows.sort((left, right) => Date.parse(String(right.submitted_at ?? right.created_at ?? 0)) - Date.parse(String(left.submitted_at ?? left.created_at ?? 0)));
      setPayments(paymentRows);
      setTracked({
        ...match,
        _latest_payment: paymentRows[0] ?? null,
        _order_status: linkedOrder ? rowText(linkedOrder, ["order_status", "status"], "Pending") : rowValue(match, ["_order_status"]),
      });
    } else {
      setTracked(null);
    }
    setSearched(true); setTrackingState(match ? "success" : "error");
  }, [session]);

  useEffect(() => {
    if (!session || !reference.trim()) return;
    void findBooking(reference);
    const interval = window.setInterval(() => { void findBooking(reference, true); }, 30000);
    return () => window.clearInterval(interval);
  }, [findBooking, reference, session]);
  useEffect(() => {
    if (!session) return;
    const refresh = () => { if (reference.trim()) void findBooking(reference, true); };
    const channel = supabase.channel(`customer-tracking-${session.user.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "reservations", filter: `customer_id=eq.${session.user.id}` }, refresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "orders", filter: `customer_id=eq.${session.user.id}` }, refresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "payments", filter: `customer_id=eq.${session.user.id}` }, refresh)
      .subscribe();
    return () => { void supabase.removeChannel(channel); };
  }, [findBooking, reference, session]);
  const submit = (event: FormEvent<HTMLFormElement>) => { event.preventDefault(); void findBooking(reference); };

  if (!session) return (
    <main className="customer-page tracking-page"><CustomerHeader /><section className="tracking-hero tracking-hero--center"><div className="tracking-hero__content"><span className="section-kicker">Private booking access</span><h1>Track Your Booking</h1><p>Sign in to view reservation status, payment progress, and private booking details.</p><a className="booking-primary tracking-signin" href="/#booking">Sign In to Continue</a></div></section><CustomerFooter /></main>
  );

  const type = tracked ? rowText(tracked, ["_record_type"], "Reservation") : "Reservation";
  const status = tracked ? bookingStatus(tracked) : "Pending Payment";
  const cancelled = status.toLowerCase().includes("cancel");
  const stages = type === "Order" ? orderTrackingStages : reservationTrackingStages;
  const stageStatus = status.toLowerCase().includes("payment") || status.toLowerCase().includes("admin approval") ? "pending" : status.toLowerCase();
  const currentStage = stages.findIndex((stage) => stage.toLowerCase() === stageStatus);
  const total = tracked ? rowNumber(tracked, ["total_amount", "total", "amount"]) : 0;
  const verifiedPaid = payments.filter((payment) => payment.demo_mode !== true && ["verified", "paid"].includes(rowText(payment, ["verification_status", "payment_status", "status"], "").toLowerCase())).reduce((sum, payment) => sum + rowNumber(payment, ["amount", "payment_amount"]), 0);
  const storedPaid = tracked ? rowNumber(tracked, ["amount_paid", "paid_amount"]) : 0;
  const amountPaid = Math.max(verifiedPaid, storedPaid);
  const stageState = (index: number) => cancelled ? "upcoming" : index < currentStage ? "completed" : index === currentStage ? "current" : "upcoming";

  return (
    <main className="customer-page tracking-page">
      <CustomerHeader />
      <section className="tracking-hero tracking-hero--center"><div className="tracking-hero__content"><span className="section-kicker">Reservation updates</span><h1>Track Your Booking</h1><p>Check your reservation status, payment progress, and booking details.</p></div><form className="tracking-search" onSubmit={submit}><label><span>Reservation or Order Reference Number</span><input aria-invalid={trackingState === "error"} onChange={(event) => { setReference(event.target.value); setTrackingState("default"); setSearched(false); }} placeholder="Enter your reference number" value={reference} /></label><StatefulButton className="booking-primary" label="Track Booking" loadingLabel="Finding Booking…" disabled={!reference.trim()} state={trackingState === "success" ? "default" : trackingState} type="submit" /></form></section>
      {trackingState === "loading" && <section className="customer-record-container"><CustomerLoadingState /></section>}
      {searched && !tracked && <section className="tracking-message tracking-message--error" role="alert"><div><Icon name="close" size={23} /></div><h2>Booking not found</h2><p>{lookupError || "No reservation or order with that reference is available to your account."}</p></section>}
      {tracked && <section className="tracking-result tracking-result--enter">
        <div className="tracking-result__header"><div><span>{type} reference</span><h2>{bookingReference(tracked)}</h2><p>Latest status from your Evently record.</p></div><span className={`tracking-result__status ${cancelled ? "tracking-result__status--cancelled" : `tracking-result__status--${status.toLowerCase()}`}`}>{status}</span></div>
        {cancelled ? <div className="tracking-cancelled"><Icon name="close" size={20} /><div><strong>This booking was cancelled</strong><span>No completion progress is shown for cancelled bookings.</span></div></div> : <div className="tracking-timeline" aria-label={`${type} progress`}>{stages.map((stage, index) => { const state = stageState(index); return <div className={`tracking-step tracking-step--${state}`} key={stage}><div className="tracking-step__marker"><span>{state === "completed" ? "✓" : index + 1}</span></div><div className="tracking-step__copy"><strong>{stage}</strong><small>{state === "completed" ? "Completed" : state === "current" ? "Current status" : "Upcoming"}</small></div></div>; })}</div>}
         {Boolean(rowValue(tracked, ["_order_status"]) ?? (type === "Order" ? rowValue(tracked, ["order_status", "status"]) : null)) && <div className="tracking-order-progress"><span>Order progress</span><strong>{rowText(tracked, ["_order_status", "order_status", "status"])}</strong></div>}
         <div className="tracking-detail-grid"><article className="tracking-information-card"><div className="tracking-card-heading"><span><Icon name="calendar" size={19} /></span><div><small>{type}</small><h3>Booking Summary</h3></div></div><dl><div><dt>Reference Number</dt><dd>{bookingReference(tracked)}</dd></div><div><dt>Service Type</dt><dd>{rowText(tracked, ["service", "service_type"])}</dd></div><div><dt>Package / Tour Slot</dt><dd>{bookingPackageLabel(tracked)}</dd></div><div><dt>Event Date</dt><dd>{bookingDate(tracked)}</dd></div><div><dt>Schedule</dt><dd>{bookingSchedule(tracked)}</dd></div><div><dt>Number of Guests</dt><dd>{rowText(tracked, ["guest_count", "guests"], "—")}</dd></div>{Boolean(rowValue(tracked, ["resource_name", "resource_key"])) && <div><dt>Venue / Resource</dt><dd>{rowText(tracked, ["resource_name", "resource_key"])}</dd></div>}<div><dt>Booking Status</dt><dd>{status}</dd></div>{type === "Order" && <div><dt>Order Status</dt><dd>{rowText(tracked, ["order_status", "status"])}</dd></div>}</dl></article>
          <article className="tracking-payment-card"><div className="tracking-card-heading"><span><Icon name="sparkle" size={19} /></span><div><small>Payments</small><h3>Payment Summary</h3></div></div><dl><div><dt>Total Booking Cost</dt><dd>{formatPhp(total)}</dd></div><div><dt>Required Deposit</dt><dd>{formatPhp(requiredDeposit(tracked))}</dd></div><div><dt>Verified Amount Paid</dt><dd className="tracking-positive-value">{formatPhp(amountPaid)}</dd></div><div className="tracking-payment-balance"><dt>Remaining Balance</dt><dd>{formatPhp(remainingBalance(tracked))}</dd></div><div><dt>Payment Method</dt><dd>{rowText(payments[0] ?? tracked, ["payment_method", "method"], "Not recorded")}</dd></div><div><dt>Payment Status</dt><dd>{paymentStatus(payments[0] ?? tracked, tracked)}</dd></div><div><dt>Payment Verification</dt><dd>{paymentVerificationStatus(payments[0] ?? tracked)}</dd></div>{payments[0] && <><div><dt>Reference</dt><dd>{rowText(payments[0], ["reference_number"], "Not recorded")}</dd></div><div><dt>Receipt</dt><dd>{rowValue(payments[0], ["proof_url"]) ? "Private receipt uploaded" : "Not uploaded"}</dd></div></>}{Boolean(rowValue(payments[0] ?? {}, ["rejection_reason", "review_notes"])) && <div><dt>Admin review note</dt><dd>{rowText(payments[0], ["rejection_reason", "review_notes"])}</dd></div>}</dl>{(payments[0] ?? {}).demo_mode === true && <p className="tracking-demo-note">Demo Payment — No Actual Money Transfer. This receipt is a demonstration record only.</p>}</article></div>
        <article className="tracking-selection-card"><div><span>Booking Details</span><p><strong>Selected Package:</strong> {bookingPackageLabel(tracked)}</p>{rowList(tracked, ["menu_items", "selected_menu", "menu"]).length > 0 && <p><strong>Catering Menu:</strong> {rowList(tracked, ["menu_items", "selected_menu", "menu"]).join(" · ")}</p>}{rowList(tracked, ["addons", "selected_addons"]).length > 0 && <p><strong>Selected Add-ons:</strong> {rowList(tracked, ["addons", "selected_addons"]).join(" · ")}</p>}<p><strong>Special Requests:</strong> {rowText(tracked, ["special_requests", "requests", "notes"], "None recorded")}</p></div></article>
      </section>}
      {!searched && trackingState !== "loading" && <section className="tracking-empty"><div><Icon name="calendar" size={28} /></div><h2>Find your booking securely</h2><p>Only bookings connected to your signed-in account can be viewed.</p></section>}
      <CustomerFooter />
    </main>
  );
}

function AdminLoginPage() {
  const navigate = useNavigate();
  const { loading: authLoading, profile, session } = useAuth();
  const [identifier, setIdentifier] = useState("");
  const [password, setPassword] = useState("");
  const [remember, setRemember] = useState(false);
  const [showPassword, setShowPassword] = useState(false);
  const [formMessage, setFormMessage] = useState("");
  const [signInState, setSignInState] = useState<AsyncState>("default");
  const [googleState, setGoogleState] = useState<AsyncState>("default");

  useEffect(() => {
    if (authLoading || !session || !profile) return;
    if (profile.role === "admin" || profile.role === "owner") navigate("/admin/dashboard", { replace: true });
    else if (profile.role === "staff" && profile.staff_active !== false) navigate("/staff/dashboard", { replace: true });
  }, [authLoading, navigate, profile, session]);

  useEffect(() => {
    const oauthError = new URLSearchParams(window.location.search).get("oauth_error");
    if (oauthError === "role_required") setFormMessage("This Google account is not provisioned for Admin or Owner access.");
    else if (oauthError) setFormMessage("Google sign-in could not be completed. Please try again.");
  }, []);

  const signIn = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setFormMessage("");
    if (!identifier.trim() || !password.trim()) {
      setSignInState("error");
      setFormMessage("Enter your email or username and password.");
      return;
    }
    setSignInState("loading");
    try {
      await signInAdmin(identifier, password, remember);
      setSignInState("success");
      navigate("/admin/dashboard", { replace: true });
    } catch (error) {
      setSignInState("error");
      const message = error instanceof Error ? error.message : "";
      setFormMessage(
        message === "Failed to fetch"
          ? "Unable to reach the authentication service. Check your connection and try again."
          : message || "Unable to sign in.",
      );
    }
  };

  const forgotPassword = async () => {
    if (!identifier.includes("@")) {
      setFormMessage("Enter the admin account email to request a password reset.");
      return;
    }
    setFormMessage("");
    try {
      await sendPasswordReset(identifier.trim(), "admin");
      setFormMessage("Password reset instructions have been sent to your email.");
    } catch (error) {
      setFormMessage(error instanceof Error ? error.message : "Unable to send reset instructions.");
    }
  };

  const continueWithGoogle = async () => {
    setGoogleState("loading");
    setFormMessage("");
    try {
      await signInWithGoogle("admin", "/admin/dashboard");
    } catch (error) {
      setGoogleState("error");
      setFormMessage(error instanceof Error ? error.message : "Unable to start Google sign in.");
    }
  };

  return (
    <main className="owner-login">
      <section className="owner-login__brand">
        <PalmAccent />
        <div className="owner-login__brand-content">
          <EventlyBrand light subtitle="Operations" />
          <p>Celebrations run better<br />with everything in view.</p>
          <div className="owner-login__brand-note">
            <Icon name="sparkle" size={17} />
            <span>Evently Management Portal</span>
          </div>
        </div>
      </section>
      <section className="owner-login__form-panel">
        <a className="owner-login__home" href="/">← Back to Evently</a>
        <form className="owner-login__form" onSubmit={signIn}>
          <EventlyBrand subtitle="Operations" />
          <span className="section-kicker">Protected admin area</span>
          <h1>Admin Login</h1>
          <p>Sign in to manage reservations, orders, payments, and Evently operations.</p>
          <label>
            <span>Email / Username</span>
            <input
              autoComplete="username"
              onChange={(event) => setIdentifier(event.target.value)}
              placeholder="name@example.com"
              required
              type="text"
              value={identifier}
            />
          </label>
          <label>
            <span>Password</span>
            <span className="owner-login__password">
              <input
                autoComplete="current-password"
                onChange={(event) => setPassword(event.target.value)}
                placeholder="Enter your password"
                required
                type={showPassword ? "text" : "password"}
                value={password}
              />
              <button
                aria-label={showPassword ? "Hide password" : "Show password"}
                onClick={() => setShowPassword((visible) => !visible)}
                type="button"
              >
                <Icon name={showPassword ? "eyeOff" : "eye"} size={17} />
                <span>{showPassword ? "Hide" : "Show"}</span>
              </button>
            </span>
          </label>
          <div className="owner-login__options">
            <label>
              <input checked={remember} onChange={(event) => setRemember(event.target.checked)} type="checkbox" />
              <span>Remember Me</span>
            </label>
            <button onClick={forgotPassword} type="button">Forgot Password?</button>
          </div>
          {formMessage && <p className="owner-login__message" role="status">{formMessage}</p>}
          <StatefulButton
            className="owner-login__submit"
            label={signInState === "success" ? "Signed In" : signInState === "error" ? "Try Again" : "Sign In"}
            loadingLabel="Signing In..."
            state={signInState}
            type="submit"
          />
          <div className="owner-login__divider"><span>OR</span></div>
          <button className="owner-login__google" disabled={googleState === "loading"} onClick={continueWithGoogle} type="button">
            {googleState === "loading" ? <span className="button-spinner button-spinner--dark" /> : <GoogleIcon />}
            <span>{googleState === "loading" ? "Connecting..." : "Continue with Google"}</span>
          </button>
          <small>Secure access for authorized Evently owners and administrators only.</small>
        </form>
      </section>
    </main>
  );
}

function StaffLoginPage() {
  const navigate = useNavigate();
  const { loading: authLoading, session, profile, profileError } = useAuth();
  const [identifier, setIdentifier] = useState("");
  const [password, setPassword] = useState("");
  const [remember, setRemember] = useState(false);
  const [showPassword, setShowPassword] = useState(false);
  const [message, setMessage] = useState("");
  const [state, setState] = useState<AsyncState>("default");
  const [googleState, setGoogleState] = useState<AsyncState>("default");

  useEffect(() => {
    const oauthError = new URLSearchParams(window.location.search).get("oauth_error");
    const messages: Record<string, string> = {
      oauth_failed: "Google sign-in was cancelled or could not be completed. Please try again.",
      missing_code: "Google did not return an authorization code. Please try again.",
      exchange_failed: "Google sign-in could not establish a Supabase session. Please try again.",
      session_failed: "The signed-in account could not be verified. Please try again.",
      profile_unavailable: "Your Evently profile could not be loaded. Contact the Owner if this continues.",
      profile_permission_denied: "Supabase denied access to your profile. Verify the authenticated profiles SELECT policy and RLS.",
      staff_role_not_configured: "Supabase reports public.profiles.role does not accept staff. Verify the public.user_role enum or role-check migration.",
      staff_role_check_denied: "Supabase denied the staff-role readiness check. Verify EXECUTE permission on evently_staff_role_ready() and the role-check RLS setup.",
      staff_role_check_unavailable: "The staff-role readiness RPC is missing from Supabase. Apply the staff-role readiness migration and reload the API schema.",
      staff_role_check_failed: "Supabase could not verify the staff role schema. Check the database logs and staff-role migration state.",
      staff_permissions_not_configured: "The staff permission tables or RPCs are not configured. Apply the Staff Dashboard migration.",
      staff_permissions_check_denied: "Supabase denied the staff permission readiness check. Verify RPC EXECUTE grants and RLS.",
      staff_permissions_check_unavailable: "The staff permission readiness RPC is missing. Apply the Staff Dashboard migration and reload the API schema.",
      staff_permissions_check_failed: "Supabase could not verify Staff Portal permissions. Check the database migration state and logs.",
      supabase_key_invalid: "The configured Supabase public API key was rejected. Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY from the same project as this staff account.",
      staff_inactive: "Staff access for this account is inactive. Contact an administrator.",
      role_required: "This Google account is not provisioned for staff access.",
    };
    if (oauthError) setMessage(messages[oauthError] ?? "Google sign-in could not be completed.");
  }, []);

  useEffect(() => {
    let active = true;
    const routeExistingSession = async () => {
      if (authLoading || !session) return;
      if (!profile) {
        const roleLookup = await supabase.rpc("evently_current_profile_role");
        if (!active) return;
        if (roleLookup.error) {
          const detail = roleLookup.error.code === "42501"
            ? "Supabase denied the profile role diagnostic RPC. Verify its EXECUTE grant and profile RLS."
            : describeSupabaseAuthError(roleLookup.error, "The profile role diagnostic failed.");
          setMessage(`Your session is active, but the staff role could not be verified: ${detail}`);
          return;
        }
        if (roleLookup.data === "staff") {
          setMessage("public.profiles.role is staff, but profile details are hidden by the current profiles SELECT RLS policy.");
          return;
        }
        if (roleLookup.data === "customer") {
          const roleReady = await supabase.rpc("evently_staff_role_ready");
          if (!active) return;
          setMessage(roleReady.error || roleReady.data !== true
            ? staffRoleReadinessMessage(roleReady.error, roleReady.data)
            : "This account is a customer account. Ask an administrator to provision it for Staff access.");
          return;
        }
        setMessage(profileError ?? "No public.profiles row is visible for the authenticated user. Verify the profile record and its SELECT RLS policy.");
        return;
      }
      if (profile.role === "staff") {
        if (profile.staff_active === false) {
          setMessage("Staff access for this account is inactive. Contact an administrator.");
          return;
        }
        const roleReady = await supabase.rpc("evently_staff_role_ready");
        if (!active) return;
        if (roleReady.error || roleReady.data !== true) {
          setMessage(staffRoleReadinessMessage(roleReady.error, roleReady.data));
          return;
        }
        const permissionsReady = await supabase.rpc("evently_staff_permissions_ready");
        if (!active) return;
        if (permissionsReady.error || permissionsReady.data !== true) {
          setMessage(staffPermissionsReadinessMessage(permissionsReady.error, permissionsReady.data));
          return;
        }
        navigate("/staff/dashboard", { replace: true });
      } else if (profile.role === "owner" || profile.role === "admin") {
        navigate("/admin/dashboard", { replace: true });
      } else {
        setMessage("You are signed in as a customer. Use an account provisioned for staff access.");
      }
    };
    void routeExistingSession();
    return () => { active = false; };
  }, [authLoading, navigate, profile, profileError, session]);

  const signIn = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setMessage("");
    setState("loading");
    try {
      const profile = await signInOperations(identifier, password, remember);
      setState("success");
      navigate(profile.role === "staff" ? "/staff/dashboard" : "/admin/dashboard", { replace: true });
    } catch (error) {
      setState("error");
      setMessage(describeSupabaseAuthError(error, "Unable to sign in."));
    }
  };
  const forgotPassword = async () => {
    if (!identifier.includes("@")) {
      setMessage("Enter your staff account email to request a password reset.");
      return;
    }
    try {
      await sendPasswordReset(identifier.trim(), "staff");
      setMessage("Password reset instructions have been sent to your email.");
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Unable to send reset instructions.");
    }
  };
  const continueWithGoogle = async () => {
    setMessage("");
    setGoogleState("loading");
    try {
      await signInWithGoogle("staff", "/staff/dashboard");
    } catch (error) {
      setGoogleState("error");
      setMessage(describeSupabaseAuthError(error, "Unable to start Google sign-in."));
    }
  };
  const signOutCurrentSession = async () => {
    await signOutUser();
    setMessage("");
    setState("default");
  };
  return (
    <main className="owner-login">
      <section className="owner-login__brand">
        <PalmAccent />
        <div className="owner-login__brand-content">
          <EventlyBrand light subtitle="STAFF OPERATIONS" />
          <p>Every detail handled<br />with care.</p>
          <div className="owner-login__brand-note">
            <Icon name="sparkle" size={17} />
            <span>Restricted Operations Access</span>
          </div>
        </div>
      </section>
      <section className="owner-login__form-panel">
        <a className="owner-login__home" href="/">← Back to Evently</a>
        <form className="owner-login__form" onSubmit={signIn}>
          <EventlyBrand subtitle="STAFF OPERATIONS" />
          <span className="section-kicker">RESTRICTED OPERATIONS ACCESS</span>
          <h1>Staff Portal Login</h1>
          <p>Sign in to review schedules and assigned reservations.</p>
          {!hasExplicitSupabaseConfiguration && <p className="owner-login__message" role="alert">NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY are not configured. Add the public credentials for your Supabase project to `.env.local`, then restart Next.js.</p>}
          <label>
            <span>Email / Username</span>
            <input
              autoComplete="username"
              onChange={(event) => setIdentifier(event.target.value)}
              placeholder="name@example.com"
              required
              type="text"
              value={identifier}
            />
          </label>
          <label>
            <span>Password</span>
            <span className="owner-login__password">
              <input
                autoComplete="current-password"
                onChange={(event) => setPassword(event.target.value)}
                placeholder="Enter your password"
                required
                type={showPassword ? "text" : "password"}
                value={password}
              />
              <button
                aria-label={showPassword ? "Hide password" : "Show password"}
                onClick={() => setShowPassword((visible) => !visible)}
                type="button"
              >
                <Icon name={showPassword ? "eyeOff" : "eye"} size={17} />
                <span>{showPassword ? "Hide" : "Show"}</span>
              </button>
            </span>
          </label>
          <div className="owner-login__options">
            <label>
              <input checked={remember} onChange={(event) => setRemember(event.target.checked)} type="checkbox" />
              <span>Remember Me</span>
            </label>
            <button onClick={() => void forgotPassword()} type="button">Forgot Password?</button>
          </div>
          {message && <p className="owner-login__message" role="alert">{message}</p>}
          <StatefulButton
            className="owner-login__submit"
            label={state === "success" ? "Signed In" : state === "error" ? "Try Again" : "Sign In"}
            loadingLabel="Signing In..."
            state={state}
            type="submit"
          />
          {session && <button className="staff-login__signout" onClick={() => void signOutCurrentSession()} type="button">Sign out of the current session</button>}
          <div className="owner-login__divider"><span>OR</span></div>
          <button className="owner-login__google" disabled={googleState === "loading" || state === "loading"} onClick={continueWithGoogle} type="button">
            {googleState === "loading" ? <span className="button-spinner button-spinner--dark" /> : <GoogleIcon />}
            <span>{googleState === "loading" ? "Connecting..." : "Continue with Google"}</span>
          </button>
          <small>Secure access for authorized EVENTLY staff accounts only.</small>
        </form>
      </section>
    </main>
  );
}

function Homepage() {
  const { loading: authLoading, profile: authProfile, session } = useAuth();
  const { hash, pathname } = useLocation();
  const [menuOpen, setMenuOpen] = useState(false);
  const [scrolled, setScrolled] = useState(false);
  const [activeSection, setActiveSection] = useState(() => window.location.hash === "#booking" ? "booking" : "home");
  const [reviewIndex, setReviewIndex] = useState(0);
  const [publicReviews, setPublicReviews] = useState<Array<{ id: string; rating: number; review: string; service: string }>>([]);
  const [lightbox, setLightbox] = useState<{ context: string; alt: string } | null>(null);
  const [bookingLoginOpen, setBookingLoginOpen] = useState(false);
  const [customerProfile, setCustomerProfile] = useState<CustomerAccountProfile | null>(() => readCustomerProfile());
  const [loginPurpose, setLoginPurpose] = useState<"booking" | "account">("booking");
  const [accountMenuOpen, setAccountMenuOpen] = useState(false);
  const [logoutConfirmOpen, setLogoutConfirmOpen] = useState(false);
  const [requestedService, setRequestedService] = useState("");
  const [staycationOptionsOpen, setStaycationOptionsOpen] = useState(false);
  const [servicesMenuOpen, setServicesMenuOpen] = useState(false);
  const authenticated = Boolean(session);
  const headerActiveSection = pathname === "/" && hash === "#booking" ? "booking" : activeSection;

  useEffect(() => {
    if (!authProfile) return;
    const customer = toCustomerAccountProfile(authProfile);
    localStorage.setItem("venice-customer-profile", JSON.stringify(customer));
    setCustomerProfile(customer);
  }, [authProfile]);

  useEffect(() => {
    const revealItems = document.querySelectorAll<HTMLElement>(
      "[data-reveal], .package-card, .gallery-item, .review-card, .reservation-intro, .reservation-shell",
    );
    revealItems.forEach((item) => item.classList.add("motion-reveal"));
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.14 },
    );
    revealItems.forEach((item) => observer.observe(item));

    const sectionIds = ["home", "services", "catering", "events", "resort", "about", "packages", "gallery", "reviews", "booking", "contact"];
    const observedSections = sectionIds.map((id) => document.getElementById(id)).filter((section): section is HTMLElement => Boolean(section));
    const normalizeSection = (id: string) => ["services", "catering", "events", "resort"].includes(id) ? "services" : id;
    const initialTarget = observedSections.find((section) => `#${section.id}` === window.location.hash);
    if (initialTarget) {
      window.requestAnimationFrame(() => {
        initialTarget.scrollIntoView();
        setActiveSection(normalizeSection(initialTarget.id));
      });
    }
    const updateActiveSection = () => {
      const focusLine = Math.min(150, window.innerHeight * .24);
      const current = observedSections
        .filter((section) => {
          const rect = section.getBoundingClientRect();
          return rect.top <= focusLine && rect.bottom > focusLine;
        })
        .at(-1);
      if (current) setActiveSection(normalizeSection(current.id));
    };
    const sectionObserver = new IntersectionObserver(updateActiveSection, {
      rootMargin: "-70px 0px -65% 0px",
      threshold: [0, .1, .35],
    });
    observedSections.forEach((section) => sectionObserver.observe(section));

    let frame = 0;
    const updateParallax = () => {
      setScrolled(window.scrollY > 45);
      updateActiveSection();
      document.querySelectorAll<HTMLElement>("[data-parallax]").forEach((item) => {
        const rect = item.getBoundingClientRect();
        const movement = (rect.top + rect.height / 2 - window.innerHeight / 2) * -0.055;
        item.style.setProperty("--parallax-y", `${movement}px`);
      });
      frame = 0;
    };
    const onScroll = () => {
      if (!frame) frame = requestAnimationFrame(updateParallax);
    };
    updateParallax();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => {
      observer.disconnect();
      sectionObserver.disconnect();
      window.removeEventListener("scroll", onScroll);
      if (frame) cancelAnimationFrame(frame);
    };
  }, []);

  useEffect(() => {
    const interval = window.setInterval(() => setReviewIndex((current) => (current + 1) % Math.max(Math.min(publicReviews.length, 3), 1)), 4800);
    return () => window.clearInterval(interval);
  }, [publicReviews.length]);

  useEffect(() => {
    let active = true;
    const loadPublishedReviews = async () => {
      const { data: reviews } = await supabase.from("reviews")
        .select("id,rating,review_text,created_at,is_published")
        .eq("is_published", true).order("created_at", { ascending: false }).limit(12);
      if (!active) return;
      setPublicReviews((reviews ?? []).map((row) => ({
        id: String(row.id), rating: Number(row.rating), review: String(row.review_text ?? ""),
        service: "Venice experience",
      })).filter((row) => row.review.trim().length > 0 && row.rating >= 1 && row.rating <= 5));
    };
    void loadPublishedReviews();
    return () => { active = false; };
  }, []);

  useEffect(() => {
    if (!lightbox) return;
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setLightbox(null);
    };
    document.body.style.overflow = "hidden";
    window.addEventListener("keydown", closeOnEscape);
    return () => {
      document.body.style.overflow = "";
      window.removeEventListener("keydown", closeOnEscape);
    };
  }, [lightbox]);

  const closeMenu = () => setMenuOpen(false);
  const continueBooking = (_mode: "login" | "account", profile?: CustomerAccountProfile) => {
    if (profile) setCustomerProfile(profile);
    setBookingLoginOpen(false);
    if (loginPurpose === "booking") {
      window.setTimeout(() => document.getElementById("booking")?.scrollIntoView({ behavior: "smooth" }), 80);
    }
  };
  const logOut = async () => {
    await signOutUser();
    localStorage.removeItem("venice-customer-profile");
    setCustomerProfile(null);
    setAccountMenuOpen(false);
    setLogoutConfirmOpen(false);
    window.scrollTo({ top: 0, behavior: "smooth" });
  };
  const profileInitials = (customerProfile?.fullName || "Venice Customer").split(" ").map((part) => part[0]).slice(0, 2).join("").toUpperCase();
  const chooseService = (serviceId: string) => {
    setRequestedService(serviceId);
    setServicesMenuOpen(false);
    setMenuOpen(false);
    window.setTimeout(() => document.getElementById("booking")?.scrollIntoView({ behavior: "smooth" }), 40);
  };
  const navItems = [
    ["Home", "#home"],
    ["Packages", "#packages"],
    ["Gallery", "#gallery"],
    ["Reviews", "#reviews"],
    ["Booking", "#booking"],
    ["Contact", "#contact"],
  ];
  const serviceLinks = [
    ["Catering", "#catering"],
    ["Resort", "#resort"],
    ["Staycation", "#services"],
  ];

  return (
    <main>
      <header className={`public-header ${scrolled ? "public-header--scrolled" : ""}`}>
        <a className="brand-link" href="#home" aria-label="Venice home"><Brand /></a>
        <nav className="public-nav" aria-label="Main navigation">
          <a aria-current={headerActiveSection === "home" ? "page" : undefined} className={headerActiveSection === "home" ? "nav-link--active" : ""} href="#home" onClick={() => setServicesMenuOpen(false)}>Home</a>
          <div className="public-services-nav">
            <button aria-expanded={servicesMenuOpen} aria-current={headerActiveSection === "services" ? "page" : undefined} className={headerActiveSection === "services" ? "nav-link--active" : ""} onClick={() => setServicesMenuOpen((open) => !open)} type="button">Services <Icon name="chevron" size={13} /></button>
            {servicesMenuOpen && <div>{serviceLinks.map(([label, href]) => <a href={href} key={label} onClick={() => setServicesMenuOpen(false)}>{label}</a>)}</div>}
          </div>
          {navItems.map(([label, href]) => (
            label !== "Home" &&
            <a aria-current={headerActiveSection === href.slice(1) ? "page" : undefined} className={headerActiveSection === href.slice(1) ? "nav-link--active" : ""} href={href} key={label} onClick={() => { setServicesMenuOpen(false); setActiveSection(href.slice(1)); }}>{label}</a>
          ))}
        </nav>
        <div className="nav-actions">
          <a className="track-link" href="/track-order">Track Order</a>
          <div className="public-account">
            {authLoading ? (
              <span className="public-account__loading" aria-label="Checking account session"><span className="state-spinner" /></span>
            ) : authenticated ? (
              <>
                <button className="public-account__avatar" aria-expanded={accountMenuOpen} aria-label="Open account menu" onClick={() => setAccountMenuOpen((open) => !open)} type="button">{profileInitials || <Icon name="people" size={18} />}</button>
                {accountMenuOpen && (
                  <div className="account-dropdown">
                    <div><span>{profileInitials}</span><p><strong>{customerProfile?.fullName || "Venice Customer"}</strong><small>{customerProfile?.email || "Customer account"}</small></p></div>
                    <a href="/account/profile"><span>👤</span> My Profile</a>
                    <a href="/account/history"><span>📋</span> Booking History</a>
                    <a href="/account/messages"><span>💬</span> Messages</a>
                    <a href="/account/history?view=orders"><span>🛍️</span> Purchase / Order History</a>
                    <a href="/account/history?view=payments"><span>💳</span> Payment History</a>
                    <a href="/account/settings"><span>⚙️</span> Account Settings</a>
                    <button onClick={() => setLogoutConfirmOpen(true)} type="button"><span>🚪</span> Log Out</button>
                  </div>
                )}
              </>
            ) : (
              <button className="public-account__signin" onClick={() => { setLoginPurpose("account"); setBookingLoginOpen(true); }} type="button"><Icon name="people" size={17} /> Sign In</button>
            )}
          </div>
        </div>
        <button
          className="menu-button"
          type="button"
          aria-expanded={menuOpen}
          aria-label={menuOpen ? "Close navigation" : "Open navigation"}
          onClick={() => setMenuOpen((open) => !open)}
        >
          <Icon name={menuOpen ? "close" : "menu"} />
        </button>
        {menuOpen && (
          <nav className="mobile-nav public-mobile-nav" aria-label="Mobile navigation">
            <a aria-current={headerActiveSection === "home" ? "page" : undefined} className={headerActiveSection === "home" ? "nav-link--active" : ""} href="#home" onClick={closeMenu}>Home</a>
            <button aria-expanded={servicesMenuOpen} className={`mobile-services-toggle ${headerActiveSection === "services" ? "nav-link--active" : ""}`} onClick={() => setServicesMenuOpen((open) => !open)} type="button">Services <Icon name="chevron" size={15} /></button>
            {servicesMenuOpen && <div className="mobile-services-submenu">{serviceLinks.map(([label, href]) => <a href={href} key={label} onClick={() => { setServicesMenuOpen(false); closeMenu(); }}>{label}</a>)}</div>}
            {navItems.filter(([label]) => label !== "Home").map(([label, href]) => <a aria-current={headerActiveSection === href.slice(1) ? "page" : undefined} className={headerActiveSection === href.slice(1) ? "nav-link--active" : ""} href={href} key={label} onClick={() => { closeMenu(); setActiveSection(href.slice(1)); }}>{label}</a>)}
            <a href="/track-order" onClick={closeMenu}>Track Order</a>
            {authLoading ? (
              <span className="mobile-account-loading">Checking account…</span>
            ) : authenticated ? (
              <>
                <a href="/account/profile" onClick={closeMenu}>My Profile</a>
                <a href="/account/history" onClick={closeMenu}>My History</a>
                <a href="/account/messages" onClick={closeMenu}>Messages</a>
                <a href="/account/settings" onClick={closeMenu}>Account Settings</a>
                <button className="mobile-account-action" onClick={() => { closeMenu(); setLogoutConfirmOpen(true); }} type="button">Log Out</button>
              </>
            ) : (
              <button className="mobile-account-action" onClick={() => { closeMenu(); setLoginPurpose("account"); setBookingLoginOpen(true); }} type="button">Sign In / Account</button>
            )}
          </nav>
        )}
      </header>

      <section className="home-hero" id="home">
        <div className="home-hero__media" data-parallax>
          <img
            alt="Tropical resort pool surrounded by lush greenery"
            decoding="async"
            fetchPriority="high"
            src="https://images.unsplash.com/photo-1596178067639-5c6e68aea6dc?auto=format&fit=crop&w=2000&q=85"
          />
        </div>
        <div className="home-hero__veil" />
        <div className="home-hero__content">
          <div className="eyebrow eyebrow--light hero-enter"><Icon name="sun" size={16} /> The Venice way</div>
          <h1 className="hero-enter hero-enter--2">Good Food.<br /><em>Beautiful Moments.</em></h1>
          <p className="hero-enter hero-enter--3">
            From generous catering and unforgettable events to restful resort stays, Venice brings
            everything together with heartfelt service and a distinctly tropical spirit.
          </p>
          <div className="home-hero__actions hero-enter hero-enter--4">
            <Button variant="booking" href="#booking">Book Your Date</Button>
            <Button variant="light" href="#catering">Explore Services</Button>
          </div>
        </div>
        <div className="home-hero__details">
          <span><Icon name="pin" size={17} /> Bulacan, Philippines</span>
          <span>Scroll to discover</span>
        </div>
        <div className="home-hero__curve" />
      </section>

      <section className="intro-strip" data-reveal id="about">
        <span className="section-kicker">One trusted destination</span>
        <h2>Every detail, from the first plate<br />to the <em>last happy memory.</em></h2>
        <p>Food, spaces, stays, and service designed around the way you want to celebrate.</p>
      </section>

      <section className="services-overview" id="services">
        <div className="services-overview__heading" data-reveal>
          <span className="section-kicker">Everything in one place</span>
          <h2>Plan Your <em>Experience.</em></h2>
          <p>Choose a thoughtfully prepared Venice experience, then personalize the details in the booking flow.</p>
        </div>
        <div className="services-overview__grid stagger-group" data-reveal>
          {[
            { label: "Catering", description: "A complete six-dish buffet with rice, dessert, drinks, and your preferred menu selections.", imageContext: "Food & Catering Photo", serviceId: "Catering" },
            { label: "Resort", description: "A welcoming tropical venue for gatherings, celebrations, and relaxed group experiences.", imageContext: "Pool & Resort Facilities Photo", serviceId: "Event" },
            { label: "Staycation", description: "Stay close to the good times with flexible day and overnight options for your group.", imageContext: "Overnight Resort Stay Photo", serviceId: "staycation" },
          ].map((experience, index) => (
            <article className={`service-overview-card service-overview-card--${index + 1}`} key={experience.label}>
              <PhotoPlaceholder context={experience.imageContext} compact className="service-overview-card__photo" />
              <span>{String(index + 1).padStart(2, "0")}</span>
              <h3>{experience.label}</h3>
              <p>{experience.description}</p>
              <button data-booking-cta={experience.serviceId === "staycation" ? undefined : "true"} onClick={() => experience.serviceId === "staycation" ? setStaycationOptionsOpen((open) => !open) : chooseService(experience.serviceId)} type="button">
                {experience.serviceId === "staycation" ? "View stay options" : "View packages"} <Icon name="arrow" size={17} />
              </button>
              {experience.serviceId === "staycation" && staycationOptionsOpen && (
                <div className="staycation-options">
                  <button data-booking-cta="true" onClick={() => chooseService("Swimming Pool")} type="button"><strong>Swimming Pool Tours</strong><small>Day, night, and overnight schedules</small></button>
                  <button data-booking-cta="true" onClick={() => chooseService("Room Accommodation")} type="button"><strong>Room Accommodation</strong><small>Standard and Kubo room options</small></button>
                </div>
              )}
            </article>
          ))}
        </div>
      </section>

      <section className="editorial-feature" id="catering">
        <div className="editorial-feature__image image-reveal" data-reveal>
          <div className="parallax-image" data-parallax>
            <img
              alt="Elegant place settings arranged for a catered celebration"
              loading="lazy"
              src="https://images.unsplash.com/photo-1561593367-66c79c2294e6?auto=format&fit=crop&w=1400&q=85"
            />
          </div>
          <span className="floating-note">Prepared with care</span>
        </div>
        <div className="editorial-feature__copy" data-reveal>
          <span className="feature-number">01 — Catering</span>
          <h2>Food that brings<br /><em>everyone closer.</em></h2>
          <p>
            Choose Basic, Standard, or Premium catering with six selected dishes, plus rice,
            dessert, and drinks. Every buffet is planned around your guest list and served with care.
          </p>
          <div className="mini-points">
            <span><Icon name="sparkle" /> Curated menus</span>
            <span><Icon name="people" /> Intimate to grand</span>
          </div>
          <button className="button button--booking inline-service-button" data-booking-cta="true" onClick={() => chooseService("Catering")} type="button"><span>Book Catering</span><Icon name="arrow" size={18} /></button>
        </div>
      </section>

      <section className="editorial-feature editorial-feature--reverse" id="events">
        <div className="editorial-feature__image image-reveal" data-reveal>
          <div className="parallax-image" data-parallax>
            <PhotoPlaceholder context="Event & Venue Photo" />
          </div>
          <span className="floating-note floating-note--orange">Made to be remembered</span>
        </div>
        <div className="editorial-feature__copy" data-reveal>
          <span className="feature-number">02 — Events</span>
          <h2>A beautiful setting<br />for <em>your story.</em></h2>
          <p>
            Weddings, birthdays, debuts, reunions, and company gatherings come to life in spaces
            that feel lush, welcoming, and full of possibility.
          </p>
          <div className="mini-points">
            <span><Icon name="calendar" /> Flexible event dates</span>
            <span><Icon name="sparkle" /> Styling support</span>
          </div>
          <button className="button button--booking inline-service-button" data-booking-cta="true" onClick={() => chooseService("Event")} type="button"><span>Book Your Event</span><Icon name="arrow" size={18} /></button>
        </div>
      </section>

      <section className="resort-showcase" id="resort">
        <div className="resort-showcase__media" data-parallax>
          <PhotoPlaceholder context="Pool & Resort Facilities Photo" />
        </div>
        <div className="resort-showcase__overlay" />
        <div className="resort-showcase__content" data-reveal>
          <span className="section-kicker section-kicker--light">03 — Resort</span>
          <h2>Stay close to<br /><em>the good times.</em></h2>
          <p>
            Come for a day tour from 8:00 AM to 3:00 PM, stay overnight, or reserve comfortable
            rooms for your group. Pool time and easy tropical moments are always close.
          </p>
          <div className="venue__facts">
            <span><Icon name="people" /> Made for groups</span>
            <span><Icon name="sun" /> Tropical open spaces</span>
          </div>
          <button className="button button--booking inline-service-button" data-booking-cta="true" onClick={() => chooseService("Swimming Pool")} type="button"><span>Reserve Your Stay</span><Icon name="arrow" size={18} /></button>
        </div>
      </section>

      <section className="packages-section" id="packages">
        <div className="packages-heading" data-reveal>
          <div>
            <span className="section-kicker">Thoughtfully bundled</span>
            <h2>Choose your kind<br />of <em>celebration.</em></h2>
          </div>
          <p>Start with a package, then make it personal with the help of our Venice team.</p>
        </div>
        <div className="package-grid stagger-group" data-reveal>
          {serviceCatalog.map((serviceOption, index) => {
            const firstPackage = serviceOption.packages[0];
            const lowestPrice = Math.min(...serviceOption.packages.map((item) => item.price).filter((price) => price > 0));
            return (
            <article className={`package-card package-card--${index + 1}`} key={serviceOption.id}>
              <PhotoPlaceholder context={serviceOption.imageContext} compact className="package-card__photo" />
              <span className="package-card__type">{serviceOption.label}</span>
              <h3>{firstPackage.name}</h3>
              <p>{firstPackage.detail}. {firstPackage.inclusions.join(" · ")}.</p>
              <div className="package-card__detail"><Icon name="people" size={18} /> {firstPackage.priceLabel ?? `Packages from ${formatPhp(lowestPrice)}`}</div>
              <button className="package-card__link" data-booking-cta="true" onClick={() => chooseService(serviceOption.id)} type="button">
                View packages <Icon name="arrow" size={18} />
              </button>
            </article>
          )})}
        </div>
      </section>

      <section className="gallery-section" id="gallery">
        <div className="gallery-heading" data-reveal>
          <span className="section-kicker">A glimpse of Venice</span>
          <h2>Moments made <em>beautiful.</em></h2>
          <a className="text-link" href="#booking">Plan Your Event <Icon name="arrow" size={17} /></a>
        </div>
        <div className="gallery-grid stagger-group" data-reveal>
          {[
            ["Resort Photo", "Venice resort and accommodations"],
            ["Food & Catering Photo", "Venice food and catering"],
            ["Events Photo", "A memorable Venice event"],
            ["Venue Photo", "Venice event venue"],
            ["Pool & Outdoor Photo", "Venice pool and outdoor facilities"],
            ["Decorations & Setups Photo", "Venice decorations and event setups"],
          ].map(([context, alt], index) => (
            <figure
              className={`gallery-item gallery-item--${index + 1}`}
              key={context}
              onClick={() => setLightbox({ context, alt })}
              onKeyDown={(event) => {
                if (event.key === "Enter" || event.key === " ") setLightbox({ context, alt });
              }}
              role="button"
              tabIndex={0}
            >
              <PhotoPlaceholder context={context} />
              <figcaption>{["Resort", "Food & Catering", "Events", "Venue", "Pool / Outdoor", "Decorations / Setups"][index]}</figcaption>
            </figure>
          ))}
        </div>
        {lightbox && (
          <div className="gallery-lightbox" role="dialog" aria-modal="true" aria-label="Gallery image">
            <button className="gallery-lightbox__backdrop" aria-label="Close image" onClick={() => setLightbox(null)} type="button" />
            <div className="gallery-lightbox__content">
              <PhotoPlaceholder context={lightbox.context} className="gallery-lightbox__placeholder" />
              <span>{lightbox.alt}</span>
              <button aria-label="Close image" onClick={() => setLightbox(null)} type="button"><Icon name="close" /></button>
            </div>
          </div>
        )}
      </section>

      <section className="reviews-section" id="reviews">
        <div className="reviews-heading" data-reveal>
          <span className="section-kicker">Words from our guests</span>
          <h2>Celebrated by<br /><em>families like yours.</em></h2>
        </div>
        <div className="review-grid stagger-group" data-reveal>
          {publicReviews.slice(0, 3).map((review, index) => (
            <article className={`review-card ${reviewIndex === index ? "review-card--active" : ""}`} key={review.id} onMouseEnter={() => setReviewIndex(index)}>
              <AnimatedRating rating={review.rating} />
              <blockquote>{review.review}</blockquote>
              <div><CustomerAvatarPlaceholder name="Verified customer" /><p><strong>Verified customer</strong><span>{review.service}</span></p></div>
            </article>
          ))}
          {!publicReviews.length && <div className="admin-chart-empty" role="status">Customer feedback will appear here after approved reviews are published.</div>}
        </div>
      </section>

      <ReservationFlow customerProfile={customerProfile} onRequireLogin={() => { setLoginPurpose("booking"); setBookingLoginOpen(true); }} requestedService={requestedService} />

      <section className="booking-cta" id="contact">
        <div className="booking-cta__media" data-parallax>
          <PhotoPlaceholder context="Final Booking & Food Photo" />
        </div>
        <div className="booking-cta__overlay" />
        <PalmAccent />
        <div className="booking-cta__content" data-reveal>
          <span className="section-kicker section-kicker--light">Your date is waiting</span>
          <h2>Ready to Make Your<br /><em>Moment Special?</em></h2>
          <p>Choose your date and let Venice take care of the rest.</p>
          <div className="booking-cta__actions">
            <Button variant="booking" href="#booking">BOOK NOW</Button>
            <Button variant="light" href="tel:+630000000000">Talk to Our Team</Button>
          </div>
        </div>
      </section>

      {bookingLoginOpen && <BookingLoginModal onClose={() => setBookingLoginOpen(false)} onContinue={continueBooking} purpose={loginPurpose} />}
      {logoutConfirmOpen && createPortal(
        <div className="logout-confirm-wrap">
          <button className="logout-confirm__backdrop" aria-label="Cancel logout" onClick={() => setLogoutConfirmOpen(false)} type="button" />
          <div className="logout-confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="logout-title">
            <span className="logout-confirm__icon"><Icon name="people" size={22} /></span>
            <span className="logout-confirm__eyebrow">Log Out</span>
            <h2 id="logout-title">Are you sure you want to log out?</h2>
            <p>You will need to sign in again to access your profile and history.</p>
            <div><button onClick={() => setLogoutConfirmOpen(false)} type="button">Cancel</button><button onClick={logOut} type="button">Log Out</button></div>
          </div>
        </div>,
        document.body,
      )}

      <footer>
        <div className="footer__top">
          <Brand light />
          <div className="footer__tagline">Good food. Beautiful moments.<br />The Venice way.</div>
          <nav className="footer__links" aria-label="Footer navigation">
            <a href="#services">Services</a>
            <a href="#packages">Packages</a>
            <a href="#gallery">Gallery</a>
            <a href="#contact">Contact</a>
          </nav>
          <div className="footer__socials">
            <a href="#facebook" aria-label="Facebook"><Icon name="facebook" /></a>
            <a href="#instagram" aria-label="Instagram"><Icon name="instagram" /></a>
          </div>
        </div>
        <div className="footer__bottom">
          <span>© {new Date().getFullYear()} Venice Catering Services &amp; Events Place</span>
          <div><span>Bulacan, Philippines</span><a href="tel:+630000000000">Call our team</a><a href="/track-order">Track an existing order</a></div>
        </div>
      </footer>
    </main>
  );
}

function PublicPage({ children }: { children: ReactNode }) {
  const location = useLocation();
  const bookingHref = location.pathname === "/" ? "#booking" : "/#booking";
  const showFloatingBooking = !["/track-order", "/order"].includes(location.pathname);

  return (
    <>
      <div className="app-page-transition">{children}</div>
      {showFloatingBooking && <FloatingBookNow href={bookingHref} />}
      {showFloatingBooking && <FloatingCustomerChat />}
    </>
  );
}

function OAuthCallbackPage() {
  const navigate = useNavigate();
  const [message, setMessage] = useState("Completing your secure sign in…");
  const [callbackError, setCallbackError] = useState(false);

  useEffect(() => {
    let active = true;
    const intent = consumeOAuthIntent();

    const completeSignIn = async () => {
      try {
        const session = await completeOAuthSession();
        const user = session.user;

        const profile = await ensureCustomerProfile(user);
        if (!active) return;

        if (profile) {
          const customerProfile = toCustomerAccountProfile(profile);
          localStorage.setItem("venice-customer-profile", JSON.stringify(customerProfile));
        }

        if (profile?.role === "staff") {
          navigate("/staff/dashboard", { replace: true });
          return;
        }
        if (profile?.role === "admin" || profile?.role === "owner") {
          const admin = await getVerifiedAdmin();
          if (admin) {
            navigate("/admin/dashboard", { replace: true });
            return;
          }
        }
        navigate(intent.area === "customer" ? intent.returnTo || "/" : "/", { replace: true });
      } catch (error) {
        if (!active) return;
        setCallbackError(true);
        setMessage(error instanceof Error ? error.message : "Google sign in could not be completed.");
      }
    };

    completeSignIn();
    return () => {
      active = false;
    };
  }, [navigate]);

  return (
    <main className="admin-auth-loading" aria-live="polite">
      <EventlyBrand />
      {!callbackError && <span className="state-spinner" />}
      <p>{message}</p>
      {callbackError && <a href="/">Return to Evently</a>}
    </main>
  );
}

function ProtectedAdminRoute() {
  const { loading: authLoading, profile, session } = useAuth();
  const location = useLocation();
  const navigate = useNavigate();
  const [access, setAccess] = useState<"loading" | "allowed" | "customer" | "unauthenticated">("loading");

  useEffect(() => {
    let active = true;
    const verifyAccess = async () => {
      if (authLoading) return;
      if (!active) return;
      if (!session) {
        setAccess("unauthenticated");
        return;
      }
      const admin = await getVerifiedAdmin();
      if (active) setAccess(admin ? "allowed" : "customer");
    };
    verifyAccess();
    return () => {
      active = false;
    };
  }, [authLoading, session]);

  if (access === "loading") {
    return (
      <main className="admin-auth-loading" aria-live="polite">
        <EventlyBrand subtitle="Operations" />
        <span className="state-spinner" />
        <p>Verifying secure access…</p>
      </main>
    );
  }
  if (access === "allowed" && profile && (profile.role === "admin" || profile.role === "owner")) {
    return <AdminDashboard navigate={navigate} path={location.pathname.split("/")[2] || "dashboard"} profile={profile} />;
  }
  if (access === "customer" && profile?.role === "staff" && profile.staff_active !== false) {
    return <Navigate replace to="/staff/dashboard" />;
  }
  if (access === "customer") {
    return (
      <main className="admin-auth-loading">
        <EventlyBrand subtitle="Access denied" />
        <p>Your account does not have permission to access Evently administration.</p>
        <a href="/">Return to the website</a>
      </main>
    );
  }
  return <Navigate replace to="/admin/login" />;
}

function ProtectedStaffRoute() {
  const { loading, profile, session } = useAuth();
  const location = useLocation();
  const navigate = useNavigate();
  if (loading) return <main className="admin-auth-loading"><EventlyBrand subtitle="Staff Portal" /><span className="state-spinner" /><p>Verifying staff access…</p></main>;
  if (!session || !profile) return <Navigate replace to="/staff/login" />;
  if (profile.role === "staff" && profile.staff_active !== false) {
    return <StaffPortal navigate={navigate} path={location.pathname.split("/")[2] || "dashboard"} profile={profile} />;
  }
  if (profile.role === "admin" || profile.role === "owner") return <Navigate replace to="/admin/dashboard" />;
  return <main className="admin-auth-loading"><EventlyBrand subtitle="Access denied" /><p>Your account does not have Staff Portal access.</p><a href="/">Return to the website</a></main>;
}

function readBrowserLocation(): AppLocation {
  return {
    hash: window.location.hash,
    pathname: window.location.pathname.replace(/\/+$/, "") || "/",
    search: window.location.search,
  };
}

function ProtectedCustomerRoute({ children }: { children: ReactNode }) {
  const { loading, session } = useAuth();
  if (loading) {
    return (
      <main className="admin-auth-loading" aria-live="polite">
        <EventlyBrand />
        <span className="state-spinner" />
        <p>Restoring your account…</p>
      </main>
    );
  }
  return session ? children : <Navigate replace to="/" />;
}

function AppRoute({ pathname }: { pathname: string }) {
  if (pathname === "/order") return <ProtectedCustomerRoute><PublicPage><OrderPage /></PublicPage></ProtectedCustomerRoute>;
  if (pathname === "/track-order") return <PublicPage><TrackOrderPage /></PublicPage>;
  if (pathname === "/account/profile") return <ProtectedCustomerRoute><PublicPage><CustomerProfilePage /></PublicPage></ProtectedCustomerRoute>;
  if (pathname === "/account/history") return <ProtectedCustomerRoute><PublicPage><CustomerHistoryPage /></PublicPage></ProtectedCustomerRoute>;
  if (pathname === "/account/messages") return <ProtectedCustomerRoute><PublicPage><CustomerMessagesPage /></PublicPage></ProtectedCustomerRoute>;
  if (pathname === "/account/settings") return <ProtectedCustomerRoute><PublicPage><CustomerAccountSettingsPage /></PublicPage></ProtectedCustomerRoute>;
  if (pathname === "/auth/callback") return <OAuthCallbackPage />;
  if (pathname === "/admin/login") return <AdminLoginPage />;
  if (pathname === "/staff/login") return <StaffLoginPage />;
  if (pathname === "/staff") return <Navigate replace to="/staff/dashboard" />;
  if (pathname.startsWith("/staff/")) return <ProtectedStaffRoute />;
  if (pathname === "/admin") return <Navigate replace to="/admin/dashboard" />;
  if (pathname.startsWith("/admin/")) return <ProtectedAdminRoute />;
  if (pathname === "/owner/login") return <Navigate replace to="/admin/login" />;
  if (pathname === "/owner/dashboard") return <Navigate replace to="/admin/dashboard" />;
  return <PublicPage><Homepage /></PublicPage>;
}

export default function App() {
  const [location, setLocation] = useState<AppLocation>(() => readBrowserLocation());

  useEffect(() => {
    const updateLocation = () => setLocation(readBrowserLocation());
    window.addEventListener("popstate", updateLocation);
    window.addEventListener("hashchange", updateLocation);
    return () => {
      window.removeEventListener("popstate", updateLocation);
      window.removeEventListener("hashchange", updateLocation);
    };
  }, []);

  const navigate = useCallback((to: string, options: NavigateOptions = {}) => {
    const destination = new URL(to, window.location.href);
    const next = `${destination.pathname}${destination.search}${destination.hash}`;
    if (options.replace) window.history.replaceState(null, "", next);
    else window.history.pushState(null, "", next);
    setLocation(readBrowserLocation());
  }, []);

  return (
    <NavigationContext.Provider value={{ location, navigate }}>
      <AuthProvider>
        <AppRoute pathname={location.pathname} />
      </AuthProvider>
    </NavigationContext.Provider>
  );
}
