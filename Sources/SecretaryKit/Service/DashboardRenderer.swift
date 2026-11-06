import Foundation

/// Renders a self-contained read-only HTML dashboard. No JavaScript, no remote
/// assets, and all observed content is HTML-escaped.
public enum DashboardRenderer {
    public static func render(_ brief: DailyBrief) -> String {
        let date = escape(brief.date)
        let timeline = brief.timeline.isEmpty
            ? "<p class=\"empty\">No memory entries for this date.</p>"
            : brief.timeline.map { entry in
                """
                <li>
                  <time>\(escape(DateCoding.timeOnly(entry.timestamp)))</time>
                  <span class="layer">\(entry.kind == .episode ? "L2" : "L3")</span>
                  <strong>\(escape(entry.title))</strong>
                  <p>\(escape(TextAnalyzer.truncated(entry.summary, limit: 280)))</p>
                  <code>\(escape(entry.memoryID))</code>
                </li>
                """
            }.joined(separator: "\n")
        let todos = brief.openTodos.isEmpty
            ? "<p class=\"empty\">No open todos.</p>"
            : brief.openTodos.map { todo in
                """
                <li class="todo">
                  <span class="box"></span>
                  <strong>\(escape(todo.title))</strong>
                  \(todo.dueAt.map { "<small>due \(escape(DateCoding.iso($0)))</small>" } ?? "")
                  <code>\(escape(todo.id))</code>
                </li>
                """
            }.joined(separator: "\n")
        let messages = brief.unreadMessages.isEmpty
            ? "<p class=\"empty\">No unread messages.</p>"
            : brief.unreadMessages.map { message in
                """
                <li class="message">
                  <strong>\(escape(message.contactName))</strong>
                  <span class="chip">\(escape(message.channel))</span>
                  <time>\(escape(DateCoding.human(message.timestamp)))</time>
                  <p>\(escape(TextAnalyzer.truncated(message.text, limit: 400)))</p>
                </li>
                """
            }.joined(separator: "\n")
        let contacts = brief.contacts.isEmpty
            ? "<p class=\"empty\">No contacts.</p>"
            : brief.contacts.map { contact in
                let channels = contact.channels
                    .map { "\($0.channel):\($0.handle)" }
                    .joined(separator: ", ")
                return """
                <li class="contact">
                  <strong>\(escape(contact.displayName))</strong>
                  \(contact.organization.map { "<span>\(escape($0))</span>" } ?? "")
                  <small>\(contact.messageCount) messages · \(escape(channels))</small>
                  \(contact.lastMessageSnippet.map { "<p>\(escape(TextAnalyzer.truncated($0, limit: 160)))</p>" } ?? "")
                </li>
                """
            }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
          <title>Private Secretary · \(date)</title>
          <style>
            :root { color-scheme: light dark; --bg:#f6f5f2; --card:#fff; --text:#1c1b19; --muted:#6b6862; --line:#ddd9d2; --accent:#2e6b5e; }
            @media (prefers-color-scheme: dark) { :root { --bg:#171817; --card:#202220; --text:#eceae5; --muted:#a19d95; --line:#353733; --accent:#7fb8a9; } }
            * { box-sizing: border-box; }
            body { margin:0; background:var(--bg); color:var(--text); font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
            main { max-width:980px; margin:0 auto; padding:40px 20px 72px; }
            header { display:flex; justify-content:space-between; align-items:baseline; gap:16px; border-bottom:1px solid var(--line); padding-bottom:18px; }
            h1 { font-size:24px; margin:0; letter-spacing:-.02em; }
            .sub, .empty, small, time, code { color:var(--muted); }
            .stats { display:flex; flex-wrap:wrap; gap:8px; margin:20px 0 28px; }
            .stats span, .chip, .layer { border:1px solid var(--line); border-radius:999px; padding:2px 9px; font-size:12px; }
            .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(320px,1fr)); gap:18px; align-items:start; }
            section { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:20px; }
            section.wide { grid-column:1/-1; }
            h2 { font-size:14px; text-transform:uppercase; letter-spacing:.08em; color:var(--accent); margin:0 0 14px; }
            ul { list-style:none; margin:0; padding:0; }
            li { border-top:1px solid var(--line); padding:12px 0; }
            li:first-child { border-top:0; padding-top:0; }
            p { margin:6px 0; }
            time { font-variant-numeric:tabular-nums; margin-right:8px; }
            code { font-size:11px; overflow-wrap:anywhere; }
            .box { display:inline-block; width:12px; height:12px; border:1.5px solid var(--accent); border-radius:3px; margin-right:8px; vertical-align:-1px; }
            .todo code, .contact small { display:block; margin-top:4px; }
            footer { color:var(--muted); font-size:12px; margin-top:28px; }
            @media (max-width:640px) { main { padding:24px 14px 48px; } header { display:block; } }
          </style>
        </head>
        <body>
        <main>
          <header>
            <div>
              <h1>Private Secretary</h1>
              <div class="sub">Read-only brief · \(date)</div>
            </div>
            <div class="sub">Generated \(escape(DateCoding.iso(brief.generatedAt)))</div>
          </header>
          <div class="stats">
            <span>\(brief.counts.episodes) episodes</span>
            <span>\(brief.counts.activeFacts) facts</span>
            <span>\(brief.counts.openTodos) open todos</span>
            <span>\(brief.counts.contacts) contacts</span>
            <span>\(brief.counts.messages) messages</span>
          </div>
          <div class="grid">
            <section class="wide">
              <h2>Timeline</h2>
              <ul>\(timeline)</ul>
            </section>
            <section>
              <h2>Open todos</h2>
              <ul>\(todos)</ul>
            </section>
            <section>
              <h2>Unread messages</h2>
              <ul>\(messages)</ul>
            </section>
            <section class="wide">
              <h2>Contacts</h2>
              <ul>\(contacts)</ul>
            </section>
          </div>
          <footer>Read-only local dashboard. Private Secretary never sends messages or executes todos.</footer>
        </main>
        </body>
        </html>
        """
    }

    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
