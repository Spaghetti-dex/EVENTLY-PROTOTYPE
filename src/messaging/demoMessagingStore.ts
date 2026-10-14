import { useSyncExternalStore } from "react";

export type DemoRole = "customer" | "admin" | "staff";
export type DemoSender = DemoRole | "demo";
export type DemoMessage = { id: string; sender: DemoSender; text: string; createdAt: string };
export type DemoConversation = {
  id: string;
  customerName: string;
  initials: string;
  topic: string;
  reservationCode?: string;
  reservationId?: string;
  messages: DemoMessage[];
  unreadFor: DemoRole[];
};
export type DemoMessagingState = { conversations: DemoConversation[] };

const nowMinus = (minutes: number) => new Date(Date.now() - minutes * 60_000).toISOString();
const makeMessage = (id: string, sender: DemoSender, text: string, minutesAgo: number): DemoMessage => ({
  id,
  sender,
  text,
  createdAt: nowMinus(minutesAgo),
});

const sampleState: DemoMessagingState = {
  conversations: [
    {
      id: "customer-support-demo",
      customerName: "Alex Demo",
      initials: "AD",
      topic: "Catering package inquiry",
      reservationCode: "DEMO-REF-1024",
      messages: [
        makeMessage("alex-1", "customer", "Hi! Can I customize the menu for a 50-guest catering package?", 42),
        makeMessage("alex-2", "demo", "Demo response: Yes, menu options can be discussed during booking. This is a scripted reply for the Evently demonstration.", 40),
      ],
      unreadFor: ["customer", "admin", "staff"],
    },
    {
      id: "maya-catering-demo",
      customerName: "Maya Sample",
      initials: "MS",
      topic: "Event preparation",
      reservationCode: "DEMO-REF-1035",
      messages: [
        makeMessage("maya-1", "customer", "What is included with the garden event package?", 155),
        makeMessage("maya-2", "demo", "Demo response: The sample garden package includes event space and the items shown in its package details. No live team member is responding.", 150),
      ],
      unreadFor: ["admin"],
    },
    {
      id: "jordan-booking-demo",
      customerName: "Jordan Example",
      initials: "JE",
      topic: "Schedule and payment question",
      reservationCode: "DEMO-REF-1048",
      messages: [
        makeMessage("jordan-1", "customer", "Could you explain when a submitted payment proof is reviewed?", 310),
        makeMessage("jordan-2", "demo", "Demo response: Payment proof and booking approval are separate steps. This scripted message does not verify a payment or change a reservation.", 305),
      ],
      unreadFor: ["staff"],
    },
  ],
};

let state = sampleState;
const listeners = new Set<() => void>();
const emit = () => {
  listeners.forEach((listener) => listener());
};
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};
const getSnapshot = () => state;
const getServerSnapshot = () => sampleState;

export function useDemoMessaging() {
  const snapshot = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
  return snapshot;
}

export function markDemoConversationRead(conversationId: string, role: DemoRole) {
  state = {
    conversations: state.conversations.map((conversation) => conversation.id === conversationId
      ? { ...conversation, unreadFor: conversation.unreadFor.filter((unreadRole) => unreadRole !== role) }
      : conversation),
  };
  emit();
}

export function toggleDemoConversationRead(conversationId: string, role: DemoRole) {
  state = {
    conversations: state.conversations.map((conversation) => {
      if (conversation.id !== conversationId) return conversation;
      const unreadFor = conversation.unreadFor.includes(role)
        ? conversation.unreadFor.filter((unreadRole) => unreadRole !== role)
        : [...conversation.unreadFor, role];
      return { ...conversation, unreadFor };
    }),
  };
  emit();
}

export function sendDemoMessage(conversationId: string, sender: DemoSender, text: string) {
  const cleaned = text.trim();
  if (!cleaned) return;
  const recipients: DemoRole[] = sender === "customer"
    ? ["admin", "staff"]
    : sender === "admin" ? ["customer", "staff"] : sender === "staff" ? ["customer", "admin"] : [];
  const message: DemoMessage = {
    id: typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`,
    sender,
    text: cleaned,
    createdAt: new Date().toISOString(),
  };
  state = {
    conversations: state.conversations.map((conversation) => conversation.id === conversationId
      ? { ...conversation, messages: [...conversation.messages, message], unreadFor: recipients }
      : conversation),
  };
  emit();
}

export function addDemoSupportReply(conversationId: string, text: string) {
  const message: DemoMessage = {
    id: typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`,
    sender: "demo",
    text,
    createdAt: new Date().toISOString(),
  };
  state = {
    conversations: state.conversations.map((conversation) => conversation.id === conversationId
      ? { ...conversation, messages: [...conversation.messages, message] }
      : conversation),
  };
  emit();
}

export function scriptedDemoReply(text: string) {
  const question = text.toLowerCase();
  let answer = "I can help with that. Please review the relevant Evently page for the latest details.";
  if (/package|price|include|inclusion/.test(question)) answer = "Package details and pricing are listed on the Evently Packages & Services page. Options shown here are sample demo information.";
  else if (/cater|menu|food|ulam/.test(question)) answer = "Catering menus are selected with the package. Menu changes and availability shown in this demo are not sent to a real team.";
  else if (/status|approve|booking|reservation/.test(question)) answer = "You can review a booking using its reference in your account. This demo reply does not read or change a real reservation.";
  else if (/schedule|time|date|slot/.test(question)) answer = "Schedule details depend on the selected package and administrator review. This is a scripted demonstration response.";
  else if (/payment|receipt|gcash|maya|bank|verify/.test(question)) answer = "Payment proof review is separate from booking approval. This scripted response does not verify or modify any payment.";
  return `Demo response: ${answer}`;
}

export function unreadDemoCount(role: DemoRole, conversations = state.conversations) {
  return conversations.filter((conversation) => conversation.unreadFor.includes(role)).length;
}
