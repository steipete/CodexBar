import assert from "node:assert/strict";
import test from "node:test";
import {
  hasPrintfArguments,
  pluralCatalogErrors,
  printfSignature,
  protectedLiteralErrors,
} from "./localization-formats.mjs";

test("printf signatures detect extra arguments, pointer types, lengths and stars", () => {
  assert.notDeepEqual(printfSignature("%d"), printfSignature("%d %s"));
  assert.notDeepEqual(printfSignature("%d"), printfSignature("%ld"));
  assert.deepEqual(printfSignature("%3$*1$.*2$f"), { 1: "d", 2: "d", 3: "f" });
  assert.deepEqual(printfSignature("%*.*f"), { 1: "d", 2: "d", 3: "f" });
  assert.deepEqual(printfSignature("%2$d %1$@"), printfSignature("%1$@ %2$d"));
  assert.deepEqual(printfSignature("%.0f%%"), { 1: "f" });
});

test("malformed and dangerous formats cannot pass signature checks", () => {
  for (const value of ["%n", "%Q", "%", "%0$d", "%1$d %1$@", "%1$d %@", "%999999999999999999999$d"]) {
    assert.throws(() => printfSignature(value), undefined, value);
  }
  assert.equal(hasPrintfArguments("Warn below 50% of quota"), false);
  assert.equal(hasPrintfArguments("%.0f%% used"), true);
});

const plural = {
  sample: {
    NSStringLocalizedFormatKey: "%#@count@",
    count: {
      NSStringFormatSpecTypeKey: "NSStringPluralRuleType",
      NSStringFormatValueTypeKey: "d",
      one: "one item",
      other: "%d items",
    },
  },
};
test("plural checks validate every branch and the template against the reference", () => {
  assert.deepEqual(pluralCatalogErrors(plural), []);
  for (const mutate of [
    (copy) => {
      copy.sample.count.other = "%@ items";
    },
    (copy) => {
      copy.sample.count.few = "%d %s items";
    },
    (copy) => {
      delete copy.sample.count.other;
    },
    (copy) => {
      copy.sample.NSStringLocalizedFormatKey = "%#@missing@";
    },
    (copy) => {
      copy.sample.NSStringLocalizedFormatKey = "%#@count@ %@";
    },
    (copy) => {
      copy.sample.count.NSStringFormatValueTypeKey = "@";
    },
    (copy) => {
      delete copy.sample;
    },
  ]) {
    const copy = structuredClone(plural);
    mutate(copy);
    assert.notEqual(pluralCatalogErrors(copy, plural).length, 0);
  }
});

test("translated technical command values retain their exact spelling", () => {
  const english = "Run npm install -g --include=optional @openai/codex@latest";
  assert.deepEqual(protectedLiteralErrors("recovery", `Voer uit: ${english}`, english), []);
  assert.equal(protectedLiteralErrors("recovery", english.replace("optional", "optioneel"), english).length, 1);
  assert.equal(
    protectedLiteralErrors("login", "gcloud auth application-default-login", "gcloud auth application-default login")
      .length,
    1,
  );
});

test("credential prefixes and environment names remain literal while prose can translate", () => {
  for (const [english, translated] of [
    ["ark-... or AKLT...", "arca-... o AKLT..."],
    ["Use org-... / org_...", "Use organización-... / org_..."],
    ["ory_session_…=…; csrftoken=…", "ory_sessie_…=…; csrftoken=…"],
    ["Set PROJECT_ID", "Set ID_PROXECTO"],
    ["Run `firectl whoami`", "Exécutez `firectl qui`"],
  ]) {
    assert.notEqual(protectedLiteralErrors("fixture", translated, english).length, 0, english);
  }
  assert.deepEqual(protectedLiteralErrors("fixture", "ark-… ou AKLT…", "ark-... or AKLT..."), []);
});

test("plural template reordering preserves variable positions", () => {
  const rules = { ...structuredClone(plural.sample), NSStringLocalizedFormatKey: "%#@count@ %#@until@" };
  rules.until = structuredClone(rules.count);
  const reference = { sample: rules };
  const reordered = structuredClone(reference);
  reordered.sample.NSStringLocalizedFormatKey = "%#@until@ %#@count@";
  assert.notEqual(pluralCatalogErrors(reordered, reference).length, 0);
  reordered.sample.NSStringLocalizedFormatKey = "%2$#@until@ %1$#@count@";
  assert.deepEqual(pluralCatalogErrors(reordered, reference), []);
});
