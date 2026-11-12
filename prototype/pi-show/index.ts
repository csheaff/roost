/**
 * Show a page beside the terminal: a throwaway prototype.
 *
 * Gives the model one tool, show_widget, whose HTML or SVG is written to a
 * folder as it streams, for a viewer (the WebKit view in Emacs) to draw. A
 * prompt the viewer drops into the folder's inbox is sent to the agent as
 * if you had typed it.
 *
 *   ROOST_SHOW_DIR=/some/folder pi -e prototype/pi-show/index.ts
 *
 * The folder holds NNN.json per page ({title, html, final}), written whole
 * each time, and inbox/*.txt, one prompt each, removed once sent.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";

const TOOL = "show_widget";
const FLUSH_MS = 150;

const DESCRIPTION = `Show the user a small visual beside the conversation: a diagram, a mock-up, a chart, or an interactive control. Use it when a picture or something to click explains better than prose; keep the explanation itself in your reply.

widget_code is one SVG element, or an HTML fragment (no doctype, html, head or body). Put style first, content next, script last. It is drawn about 680px wide on a transparent background, in light or dark mode: use these CSS variables for colour, never fixed ones: --text-primary, --text-secondary, --text-muted, --surface-1, --surface-2, --border, --border-strong, --text-accent, --text-danger, --text-success, --text-warning, --radius, --font-sans, --font-mono. Buttons, inputs and sliders are styled already. In SVG use viewBox="0 0 680 H", give text class "t", "th" (bold) or "ts" (small), and colour a group or shape with class c-purple, c-teal, c-coral, c-pink, c-gray, c-blue, c-green, c-amber or c-red.

Handle sliders, toggles and sums in the widget's own script. Call sendPrompt(text) from a click when the user's next step needs you: it sends text as their next message. Scripts may load libraries only from cdnjs.cloudflare.com, cdn.jsdelivr.net, unpkg.com or esm.sh.`;

export default function (pi: ExtensionAPI) {
	const dir = process.env.ROOST_SHOW_DIR || path.join(os.tmpdir(), "roost-show");
	const inbox = path.join(dir, "inbox");
	fs.mkdirSync(inbox, { recursive: true });

	// Pages already in the folder keep their numbers; new ones follow.
	let count = fs.readdirSync(dir).filter((name) => /^\d+\.json$/.test(name)).length;
	const pages = new Map<string, { file: string; timer?: NodeJS.Timeout; latest?: object }>();

	function page(key: string) {
		let found = pages.get(key);
		if (!found) {
			count += 1;
			found = { file: path.join(dir, `${String(count).padStart(3, "0")}.json`) };
			pages.set(key, found);
		}
		return found;
	}

	function write(file: string, data: object) {
		const partial = `${file}.part`;
		fs.writeFileSync(partial, JSON.stringify(data));
		fs.renameSync(partial, file);
	}

	function show(key: string, title: unknown, html: unknown, final: boolean) {
		if (typeof html !== "string" || !html) return;
		const found = page(key);
		found.latest = { title: typeof title === "string" ? title : "", html, final };
		if (final) {
			clearTimeout(found.timer);
			found.timer = undefined;
			write(found.file, found.latest);
		} else if (!found.timer) {
			found.timer = setTimeout(() => {
				found.timer = undefined;
				if (found.latest) write(found.file, found.latest);
			}, FLUSH_MS);
		}
	}

	// The page appears as the model writes it, not when it has finished.
	pi.on("message_update", async (event) => {
		const update = event.assistantMessageEvent as any;
		if (!update || !String(update.type).startsWith("toolcall_")) return;
		const call = update.type === "toolcall_end" ? update.toolCall : update.partial?.content?.[update.contentIndex];
		if (call?.type !== "toolCall" || call.name !== TOOL) return;
		const key = call.id || `${event.message?.timestamp ?? ""}:${update.contentIndex}`;
		show(key, call.arguments?.title, call.arguments?.widget_code, false);
	});

	pi.registerTool(
		defineTool({
			name: TOOL,
			label: "Show",
			description: DESCRIPTION,
			parameters: Type.Object({
				title: Type.String({ description: "A short name for the visual, in snake_case" }),
				widget_code: Type.String({ description: "One SVG element, or an HTML fragment" }),
			}),
			async execute(toolCallId, params) {
				show(toolCallId, params.title, params.widget_code, true);
				return {
					content: [{ type: "text", text: "Shown to the user beside the conversation." }],
					details: { title: params.title },
				};
			},
		}),
	);

	// What the user clicks in a page comes back as their next message.
	let watcher: fs.FSWatcher | undefined;
	pi.on("session_start", async (_event, ctx) => {
		const drain = () => {
			for (const name of fs.readdirSync(inbox).sort()) {
				if (!name.endsWith(".txt")) continue;
				const file = path.join(inbox, name);
				let text = "";
				try {
					text = fs.readFileSync(file, "utf-8").trim();
					fs.unlinkSync(file);
				} catch {
					continue;
				}
				if (!text) continue;
				if (ctx.isIdle()) pi.sendUserMessage(text);
				else pi.sendUserMessage(text, { deliverAs: "followUp" });
			}
		};
		watcher?.close();
		watcher = fs.watch(inbox, drain);
		drain();
	});

	pi.on("session_shutdown", async () => {
		watcher?.close();
		watcher = undefined;
	});
}
