import EventlyApplication from "../evently-application";

// proxy.ts performs cookie refresh and server-side role gating for these paths.
// Keep the existing client router mounted after that boundary to preserve routes.
export default function RoutePage() {
  return <EventlyApplication />;
}
