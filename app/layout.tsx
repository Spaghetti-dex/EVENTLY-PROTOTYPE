import type { Metadata } from "next";
import { Suspense } from "react";
import "../src/index.css";
import "../src/admin/admin.css";

export const metadata: Metadata = {
  title: "Venice Catering System",
  description: "Explore Venice Catering Services and Events Place, offering elegant event planning, premium catering, and resort accommodations in a tropical setting.",
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>
        <Suspense fallback={<main className="admin-auth-loading"><span className="state-spinner" /><p>Loading Evently…</p></main>}>
          {children}
        </Suspense>
      </body>
    </html>
  );
}
