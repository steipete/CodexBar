class RecordingElement {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.textContent = "";
    this.children = [];
    this.attributes = {};
    this.style = {setProperty() {}};
    this.classList = {
      add: value => this.className = [...new Set([...this.className.split(" "), value])].join(" "),
      remove: value => this.className = this.className.split(" ").filter(item => item !== value).join(" "),
      toggle: (value, enabled) => enabled ? this.classList.add(value) : this.classList.remove(value)
    };
  }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute(key, value) { this.attributes[key] = String(value); }
  addEventListener() {}
  get childElementCount() { return this.children.length; }
}
const recordingElements = {};
const document = {
  createElement: tag => new RecordingElement(tag),
  createElementNS: (_, tag) => new RecordingElement(tag),
  getElementById: id => recordingElements[id] ||= new RecordingElement("div")
};
const localStorage = {getItem: () => null, setItem() {}, removeItem() {}};
const fetch = () => new Promise(() => {});
const setTimeout = () => 0;
const setInterval = () => 0;
const clearTimeout = () => {};
function recordedNodes(root) {
  return [root, ...root.children.flatMap(recordedNodes)];
}
function recordedText(root) {
  return recordedNodes(root).map(element => element.textContent).filter(Boolean);
}
