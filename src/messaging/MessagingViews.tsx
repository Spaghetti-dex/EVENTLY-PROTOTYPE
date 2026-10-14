import { useEffect, useMemo, useRef, useState, type FormEvent, type KeyboardEvent } from "react";
import { ArrowLeft, ArrowUpRight, MessageCircle, Search, Send, ShieldCheck, X } from "lucide-react";
import {
  addDemoSupportReply,
  markDemoConversationRead,
  scriptedDemoReply,
  sendDemoMessage,
  toggleDemoConversationRead,
  unreadDemoCount,
  useDemoMessaging,
  type DemoConversation,
  type DemoMessage,
  type DemoRole,
} from "./demoMessagingStore";

const previewOf = (conversation: DemoConversation) => conversation.messages.at(-1)?.text ?? "No messages yet";
const timeLabel = (value?: string) => {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const today = new Date().toDateString() === date.toDateString();
  return today
    ? date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    : date.toLocaleDateString([], { month: "short", day: "numeric" });
};
const fullTimeLabel = (value: string) => new Date(value).toLocaleString([], { dateStyle: "medium", timeStyle: "short" });
const isStaffSide = (sender: DemoMessage["sender"]) => sender === "admin" || sender === "staff";
const isReservationId = (value?: string) => Boolean(value && /^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(value));

function useScriptedCustomerReply(conversationId: string, enabled: boolean) {
  const timers = useRef<Set<number>>(new Set());
  useEffect(() => () => {
    timers.current.forEach((timer) => window.clearTimeout(timer));
    timers.current.clear();
  }, []);
  return (text: string) => {
    if (!enabled) return;
    const timer = window.setTimeout(() => {
      timers.current.delete(timer);
      addDemoSupportReply(conversationId, scriptedDemoReply(text));
    }, 950);
    timers.current.add(timer);
  };
}

function MessageComposer({ onSend, placeholder }: { onSend: (message: string) => void; placeholder: string }) {
  const [draft, setDraft] = useState("");
  const submit = (event?: FormEvent) => {
    event?.preventDefault();
    const message = draft.trim();
    if (!message) return;
    onSend(message);
    setDraft("");
  };
  const handleKey = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      submit();
    }
  };
  return <form className="demo-chat-composer" onSubmit={submit}>
    <textarea aria-label="Write a message" onChange={(event) => setDraft(event.target.value)} onKeyDown={handleKey} placeholder={placeholder} rows={2} value={draft} />
    <button aria-label="Send message" disabled={!draft.trim()} type="submit"><Send size={17} /><span>Send</span></button>
  </form>;
}

function MessageThread({
  conversation,
  role,
  onBack,
  onClose,
  onViewReservation,
}: {
  conversation: DemoConversation;
  role: DemoRole;
  onBack?: () => void;
  onClose?: () => void;
  onViewReservation?: (id: string) => void;
}) {
  const messageList = useRef<HTMLDivElement | null>(null);
  const scheduleReply = useScriptedCustomerReply(conversation.id, role === "customer");
  useEffect(() => {
    if (messageList.current) messageList.current.scrollTop = messageList.current.scrollHeight;
  }, [conversation.id, conversation.messages.length]);
  const send = (message: string) => {
    sendDemoMessage(conversation.id, role, message);
    scheduleReply(message);
  };
  const unread = conversation.unreadFor.includes(role);
  return <section className={`demo-chat-thread demo-chat-thread--${role}`} aria-label={`Conversation with ${conversation.customerName}`}>
    <header className="demo-chat-thread__header">
      {onBack && <button aria-label="Back to conversations" className="demo-chat-back" onClick={onBack} type="button"><ArrowLeft size={18} /></button>}
      <span className="demo-chat-avatar">{role === "customer" ? <ShieldCheck size={19} /> : conversation.initials}</span>
      <div className="demo-chat-thread__identity"><strong>{role === "customer" ? "Evently Support" : conversation.customerName}</strong><small>{role === "customer" ? <><i className="demo-chat-online-dot" />Demo available · scripted responses</> : `${conversation.topic} · Demo Chat`}</small></div>
      {role !== "customer" && <button className={`demo-chat-read-toggle ${unread ? "is-unread" : ""}`} onClick={() => toggleDemoConversationRead(conversation.id, role)} type="button">{unread ? "Mark read" : "Mark unread"}</button>}
      {onClose && <button aria-label="Minimize chat" className="demo-chat-close" onClick={onClose} type="button"><X size={18} /></button>}
    </header>
    {role !== "customer" && conversation.reservationCode && <div className="demo-chat-reference"><span>Related demo reservation</span><strong>{conversation.reservationCode}</strong>{isReservationId(conversation.reservationId) && onViewReservation && <button onClick={() => onViewReservation(conversation.reservationId!)} type="button">View reservation <ArrowUpRight size={14} /></button>}</div>}
    {role === "customer" && <div className="demo-chat-demo-note">Demo Chat: replies are scripted and are not sent by a real Evently employee.</div>}
    <div className="demo-chat-messages" ref={messageList}>
      {conversation.messages.map((message) => {
        const own = role === "customer" ? message.sender === "customer" : isStaffSide(message.sender);
        const senderLabel = message.sender === "demo" ? "Scripted demo response" : message.sender === "customer" ? conversation.customerName : message.sender === "admin" ? "Admin demo reply" : "Staff demo reply";
        return <article className={`demo-chat-message ${own ? "is-own" : "is-other"} ${message.sender === "demo" ? "is-scripted" : ""}`} key={message.id}>
          <div><small>{senderLabel}</small><p>{message.text}</p><time dateTime={message.createdAt}>{fullTimeLabel(message.createdAt)}</time></div>
        </article>;
      })}
    </div>
    <MessageComposer onSend={send} placeholder={role === "customer" ? "Write a message… (Shift+Enter for a new line)" : "Reply to this demo conversation…"} />
  </section>;
}

export function MessagingInbox({ role, onViewReservation }: { role: "admin" | "staff"; onViewReservation?: (id: string) => void }) {
  const { conversations } = useDemoMessaging();
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<"all" | "unread">("all");
  const [mobileChatOpen, setMobileChatOpen] = useState(false);
  const selected = conversations.find((conversation) => conversation.id === selectedId) ?? null;
  const filtered = useMemo(() => conversations
    .filter((conversation) => filter === "all" || conversation.unreadFor.includes(role))
    .filter((conversation) => `${conversation.customerName} ${conversation.topic} ${conversation.reservationCode ?? ""} ${conversation.messages.map((message) => message.text).join(" ")}`.toLowerCase().includes(search.trim().toLowerCase()))
    .sort((left, right) => Date.parse(right.messages.at(-1)?.createdAt ?? "") - Date.parse(left.messages.at(-1)?.createdAt ?? "")), [conversations, filter, role, search]);
  useEffect(() => {
    if (selected) markDemoConversationRead(selected.id, role);
  }, [selectedId, role]);
  const selectConversation = (id: string) => {
    setSelectedId(id);
    setMobileChatOpen(true);
    markDemoConversationRead(id, role);
  };
  return <section className={`demo-messaging-inbox ${mobileChatOpen ? "is-mobile-chat-open" : ""}`} aria-label="Demo messaging inbox">
    <aside className="demo-conversation-panel">
      <div className="demo-inbox-heading"><div><span>Demo Chat</span><h2>Messages</h2></div><b>{unreadDemoCount(role, conversations)}</b></div>
      <label className="demo-conversation-search"><Search size={16} /><input aria-label="Search conversations" onChange={(event) => setSearch(event.target.value)} placeholder="Search conversations" value={search} /></label>
      <div className="demo-conversation-filters" role="group" aria-label="Filter conversations">
        <button aria-pressed={filter === "all"} className={filter === "all" ? "is-active" : ""} onClick={() => setFilter("all")} type="button">All</button>
        <button aria-pressed={filter === "unread"} className={filter === "unread" ? "is-active" : ""} onClick={() => setFilter("unread")} type="button">Unread</button>
      </div>
      <div className="demo-conversation-list">
        {filtered.map((conversation) => <button className={`demo-conversation-item ${conversation.id === selectedId ? "is-selected" : ""}`} key={conversation.id} onClick={() => selectConversation(conversation.id)} type="button">
          <span className="demo-conversation-avatar">{conversation.initials}</span>
          <span className="demo-conversation-item__body"><strong>{conversation.customerName}</strong><small>{previewOf(conversation)}</small><em>{conversation.reservationCode ?? conversation.topic}</em></span>
          <span className="demo-conversation-item__meta"><time>{timeLabel(conversation.messages.at(-1)?.createdAt)}</time>{conversation.unreadFor.includes(role) && <i aria-label="Unread conversation" />}</span>
        </button>)}
        {!filtered.length && <p className="demo-chat-empty">No demo conversations match.</p>}
      </div>
    </aside>
    <div className="demo-inbox-thread-panel">
      {selected ? <MessageThread conversation={selected} onBack={() => setMobileChatOpen(false)} onViewReservation={onViewReservation} role={role} /> : <div className="demo-inbox-empty"><MessageCircle size={28} /><strong>Select a conversation</strong><span>Messages here are fictional and stored only in this browser demo.</span></div>}
    </div>
  </section>;
}

export function CustomerMessagesPanel() {
  const { conversations } = useDemoMessaging();
  const conversation = conversations.find((item) => item.id === "customer-support-demo") ?? conversations[0];
  useEffect(() => {
    if (conversation) markDemoConversationRead(conversation.id, "customer");
  }, [conversation?.id]);
  return conversation
    ? <div className="demo-customer-messages-page"><div className="demo-chat-page-label"><MessageCircle size={18} /><span>Demo Chat · replies are scripted for this demonstration.</span></div><MessageThread conversation={conversation} role="customer" /></div>
    : <p className="demo-chat-empty">No demo conversation is available.</p>;
}

export function FloatingCustomerChat() {
  const { conversations } = useDemoMessaging();
  const [open, setOpen] = useState(false);
  const unread = unreadDemoCount("customer", conversations);
  const conversation = conversations.find((item) => item.id === "customer-support-demo") ?? conversations[0];
  useEffect(() => {
    if (open && conversation) markDemoConversationRead(conversation.id, "customer");
  }, [open, conversation?.id]);
  return <div className={`demo-floating-chat ${open ? "is-open" : ""}`}>
    {open && conversation && <MessageThread conversation={conversation} onClose={() => setOpen(false)} role="customer" />}
    <button aria-expanded={open} aria-label={open ? "Close Evently Support chat" : `Open Evently Support chat${unread ? `, ${unread} unread messages` : ""}`} className="demo-floating-chat__trigger" onClick={() => setOpen((value) => !value)} type="button">
      {open ? <X size={22} /> : <MessageCircle size={22} />}
      {!open && unread > 0 && <span aria-label={`${unread} unread demo messages`}>{unread}</span>}
    </button>
  </div>;
}
