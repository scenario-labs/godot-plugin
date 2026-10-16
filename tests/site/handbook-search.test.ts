// Run from the repository root: node --test tests/site/handbook-search.test.ts (make site-test)
// From the Blender plugin (GPL-3.0-or-later there); Scenario Inc., the copyright
// holder of both, publishes this copy under MIT.
import assert from "node:assert/strict";
import { test } from "node:test";

import handbook from "../../docs/site/handbook-search.js";

const { search, attach } = handbook;

const SECTIONS = [
  { id: "install", title: "Install", trail: "", text: "Extract the zip at the root of the project, or clone the repository." },
  { id: "updates", title: "Updates", trail: "Install", text: "Godot keeps the plugin in your project; check for updates in the Asset Library." },
  { id: "materials", title: "Materials", trail: "Lanes", text: "Generate PBR texture sets and apply them to a mesh material slot." },
  { id: "costs", title: "Costs", trail: "", text: "Every estimate is shown in Creative Units before you install nothing or spend." },
  { id: "3d", title: "3D", trail: "Lanes", text: "Génération of meshes from an image or a prompt." },
];

const ids = (query: string, limit?: number) => search(SECTIONS, query, limit).map((result) => result.section.id);

test("finds nothing for an empty query", () => {
  assert.deepEqual(ids(""), []);
  assert.deepEqual(ids("   "), []);
});

test("ranks a title match above the text, and the text above the parent title", () => {
  assert.deepEqual(ids("install"), ["install", "costs", "updates"]);
  assert.deepEqual(ids("install updates"), ["updates"]);
});

test("matches the start of a word while typing", () => {
  assert.deepEqual(ids("mater"), ["materials"]);
});

test("tolerates a typo in a longer word", () => {
  assert.deepEqual(ids("matreials"), ["materials"]);
  assert.deepEqual(ids("repostory"), ["install"]);
});

test("ranks a misspelt start of a title word above the same typo in the text", () => {
  const sections = [
    { id: "intro", title: "What it does", trail: "", text: "Apply a material to the mesh." },
    { id: "materials", title: "Materials", trail: "Lanes", text: "Texture sets for a slot." },
  ];

  assert.deepEqual(
    search(sections, "matreial").map((result) => result.section.id),
    ["materials", "intro"],
  );
});

test("allows a typo by the length of the word in the guide, not the query", () => {
  const sections = [{ id: "image", title: "Image", trail: "Lanes", text: "Generate a still." }];

  assert.deepEqual(
    search(sections, "imge").map((result) => result.section.id),
    ["image"],
  );
  assert.deepEqual(ids("repostry"), ["install"]);
});

test("does not guess a typo in a word of four letters", () => {
  assert.deepEqual(ids("mesj"), []);
});

test("does not guess typos in short words", () => {
  assert.deepEqual(ids("cist"), []);
});

test("requires every word of the query", () => {
  assert.deepEqual(ids("texture mesh"), ["materials"]);
  assert.deepEqual(ids("texture repository"), []);
});

test("ignores case and accents", () => {
  assert.deepEqual(ids("GENERATION"), ["3d"]);
  assert.deepEqual(ids("3d"), ["3d"]);
});

test("returns at most the requested number of results", () => {
  assert.equal(ids("e", 2).length, 2);
});

test("highlights matched words in a snippet that preserves the original text", () => {
  const [result] = search(SECTIONS, "texture slot");

  const text = result.snippet.map((segment) => segment.text).join("");
  assert.ok(SECTIONS[2].text.includes(text.replace(/^…|…$/g, "")));
  assert.deepEqual(
    result.snippet.filter((segment) => segment.match).map((segment) => segment.text),
    ["texture", "slot"],
  );
});

test("highlights the matched part of the title", () => {
  const [result] = search(SECTIONS, "upd");

  assert.deepEqual(result.title, [{ text: "Updates", match: true }]);
});

test("shortens a long text around the first match", () => {
  const long = { id: "long", title: "Long", trail: "", text: `${"filler ".repeat(40)}needle ${"filler ".repeat(40)}` };

  const [result] = search([long], "needle");
  const text = result.snippet.map((segment) => segment.text).join("");

  assert.ok(text.startsWith("…") && text.endsWith("…"));
  assert.ok(text.length < 200);
  assert.ok(text.includes("needle"));
});

// A minimal stand-in for the few DOM features attach() uses.
class FakeElement {
  tagName: string;
  id = "";
  className = "";
  hidden = false;
  value = "";
  href = "";
  tabIndex = 0;
  isContentEditable = false;
  clicks = 0;
  parentElement: FakeElement | null = null;
  childNodes: (FakeElement | string)[] = [];
  attributes = new Map<string, string>();
  listeners = new Map<string, ((event: unknown) => void)[]>();
  document: FakeDocument;
  constructor(document: FakeDocument, tag: string) {
    this.document = document;
    this.tagName = tag.toUpperCase();
  }
  get children() {
    return this.childNodes.filter((node): node is FakeElement => node instanceof FakeElement);
  }
  get textContent(): string {
    return this.childNodes.map((node) => (typeof node === "string" ? node : node.textContent)).join("");
  }
  set textContent(text: string) {
    this.childNodes = [text];
  }
  append(...nodes: (FakeElement | string)[]) {
    for (const node of nodes) {
      if (node instanceof FakeElement) node.parentElement = this;
      this.childNodes.push(node);
    }
  }
  replaceChildren() {
    this.childNodes = [];
  }
  setAttribute(name: string, value: string) {
    this.attributes.set(name, value);
  }
  getAttribute(name: string) {
    return this.attributes.get(name) ?? null;
  }
  removeAttribute(name: string) {
    this.attributes.delete(name);
  }
  addEventListener(type: string, listener: (event: unknown) => void) {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }
  dispatch(type: string, event: Record<string, unknown> = {}) {
    const full = { target: this, preventDefault() {}, ...event };
    for (const listener of this.listeners.get(type) ?? []) listener(full);
    if (type === "keydown" || type === "click") this.document.dispatch(type, full);
  }
  closest(selector: string): FakeElement | null {
    const matches = (node: FakeElement) =>
      selector.startsWith(".") ? node.className.split(" ").includes(selector.slice(1)) : node.tagName === selector.toUpperCase();
    for (let node: FakeElement | null = this; node; node = node.parentElement) if (matches(node)) return node;
    return null;
  }
  contains(other: unknown) {
    for (let node = other as FakeElement | null; node; node = node.parentElement) if (node === this) return true;
    return false;
  }
  scrollIntoView() {}
  focus() {
    this.document.activeElement = this;
  }
  blur() {
    this.document.activeElement = null;
  }
  select() {}
  click() {
    this.clicks++;
  }
}

class FakeDocument {
  activeElement: FakeElement | null = null;
  elements = new Map<string, FakeElement>();
  article: FakeElement;
  listeners = new Map<string, ((event: unknown) => void)[]>();
  constructor() {
    const search = this.make("div", "", "search");
    for (const [tag, id] of [["input", "search-input"], ["div", "search-panel"], ["ul", "search-results"], ["p", "search-status"]]) {
      const element = this.make(tag, id);
      search.append(element);
      this.elements.set(id, element);
    }
    this.article = this.make("article", "", "handbook");
    for (const [tag, id, text] of [
      ["h2", "install", "Install"],
      ["p", "", "Extract the zip at the root of the project, or clone the repository."],
      ["h2", "updates", "Updates"],
      ["p", "", "Godot keeps the plugin in your project."],
    ]) {
      const element = this.make(tag, id);
      element.textContent = text;
      this.article.append(element);
    }
  }
  make(tag: string, id = "", className = "") {
    const element = new FakeElement(this, tag);
    element.id = id;
    element.className = className;
    return element;
  }
  getElementById(id: string) {
    return this.elements.get(id) ?? null;
  }
  querySelector(selector: string) {
    return selector === ".handbook" ? this.article : null;
  }
  createElement(tag: string) {
    return this.make(tag);
  }
  addEventListener(type: string, listener: (event: unknown) => void) {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }
  dispatch(type: string, event: unknown) {
    for (const listener of this.listeners.get(type) ?? []) listener(event);
  }
}

function page() {
  const globals = globalThis as Record<string, unknown>;
  for (const name of ["Element", "HTMLElement", "Node"]) globals[name] = FakeElement;
  const document = new FakeDocument();
  attach(document as unknown as Document);
  const input = document.getElementById("search-input") as FakeElement;
  const type = (text: string) => {
    input.value = text;
    input.dispatch("input");
  };
  const press = (key: string) => input.dispatch("keydown", { key });
  const links = () => (document.getElementById("search-results") as FakeElement).children.map((item) => item.children[0]);
  return { document, input, type, press, links };
}

test("opens the selected result with Enter", () => {
  const { type, press, links } = page();

  type("updates");
  const [link] = links();
  press("Enter");

  assert.equal(link.href, "#updates");
  assert.equal(link.clicks, 1);
});

test("does nothing on Enter or the arrow keys once Escape closed the results", () => {
  const { document, input, type, press, links } = page();

  type("install");
  const opened = links();
  press("Escape");
  press("ArrowDown");
  press("Enter");

  assert.equal((document.getElementById("search-panel") as FakeElement).hidden, true);
  assert.deepEqual(opened.map((link) => link.clicks), opened.map(() => 0));
  assert.equal(input.getAttribute("aria-activedescendant"), null);
  assert.deepEqual(links(), []);
});
