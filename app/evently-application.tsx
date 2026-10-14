"use client";

import dynamic from "next/dynamic";

const EventlyApp = dynamic(() => import("../src/App"), {
  ssr: false,
  loading: () => <main className="admin-auth-loading"><span className="state-spinner" /><p>Loading Evently…</p></main>,
});

export default function EventlyApplication() {
  return <EventlyApp />;
}
