// Keep format validation independent of catalogs so malformed translations can be tested safely.
const conversionPattern =
  /^%(?:(\d+)\$)?[-+#0 ]*(?:(\*)(?:(\d+)\$)?|\d+)?(?:\.(?:(\*)(?:(\d+)\$)?|\d+))?(hh|ll|[hlqLzjt])?([@diouxXfFeEgGaAcCsSpn])/;

export function hasPrintfArguments(value) {
  // Ordinary prose such as "50% of quota" is not a printf format.
  return /%(?:\d+\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlqLzjt])?[@diouxXfFeEgGaAcCsSpn]/.test(
    value.replace(/%%/g, ""),
  );
}

export function printfSignature(value) {
  const signature = {};
  let implicitIndex = 1;
  let usesImplicit = false;
  let usesExplicit = false;
  function consume(position, type) {
    const slot = position ? Number(position) : implicitIndex++;
    if (!Number.isSafeInteger(slot) || slot < 1 || slot > 99) throw new Error("invalid argument position");
    usesExplicit ||= Boolean(position);
    usesImplicit ||= !position;
    if (usesExplicit && usesImplicit) throw new Error("mixed positional and implicit arguments");
    if (Object.hasOwn(signature, slot) && signature[slot] !== type) {
      throw new Error(`conflicting types for argument ${slot}`);
    }
    signature[slot] = type;
  }
  for (let index = 0; index < value.length; index++) {
    if (value[index] !== "%") continue;
    if (value[index + 1] === "%") {
      index++;
      continue;
    }
    const match = value.slice(index).match(conversionPattern);
    if (!match) throw new Error(`unsupported format at offset ${index}`);
    const [, position, width, widthPosition, precision, precisionPosition, length = "", conversion] = match;
    if (conversion === "n") throw new Error("%n is not permitted in localization formats");
    if (width) consume(widthPosition, "d");
    if (precision) consume(precisionPosition, "d");
    consume(position, length + conversion);
    index += match[0].length - 1;
  }
  return signature;
}

export function pluralCatalogErrors(catalog, reference = catalog) {
  const errors = [];
  for (const key of new Set([...Object.keys(reference), ...Object.keys(catalog)])) {
    const entry = catalog[key];
    const original = reference[key];
    if (!entry || !original) {
      errors.push(`${key}: missing or unexpected plural key`);
      continue;
    }
    try {
      function templateSignature(rules) {
        if (typeof rules.NSStringLocalizedFormatKey !== "string") throw new Error("missing format template");
        const variables = new Set();
        const bindings = {};
        let implicitPosition = 1;
        const format = rules.NSStringLocalizedFormatKey.replace(/%(\d+\$)?#@([^@]+)@/g, (_, position = "", name) => {
          const rule = rules[name];
          if (!rule || rule.NSStringFormatSpecTypeKey !== "NSStringPluralRuleType") {
            throw new Error(`missing plural rule ${name}`);
          }
          const type = rule.NSStringFormatValueTypeKey;
          if (typeof type !== "string" || !/^(?:hh|ll|[hlqzjt])?[diuoxX]$/.test(type)) {
            throw new Error(`unsupported plural variable type ${name}`);
          }
          variables.add(name);
          bindings[position ? Number(position.slice(0, -1)) : implicitPosition++] = `${name}:${type}`;
          return `%${position}${type}`;
        });
        if (variables.size === 0) throw new Error("missing plural variable reference");
        return { signature: printfSignature(format), variables, bindings };
      }
      const expected = templateSignature(original);
      const actual = templateSignature(entry);
      if (JSON.stringify(actual.signature) !== JSON.stringify(expected.signature)) {
        throw new Error("plural template argument types or positions differ");
      }
      if (JSON.stringify(actual.bindings) !== JSON.stringify(expected.bindings)) {
        throw new Error("plural variables use different argument positions");
      }
      for (const name of actual.variables) {
        const rule = entry[name];
        if (typeof rule.other !== "string" || !rule.other.trim()) throw new Error(`${name}: missing other branch`);
        const expectedType = printfSignature(`%${rule.NSStringFormatValueTypeKey}`)[1];
        for (const [branch, value] of Object.entries(rule)) {
          if (branch.startsWith("NSString")) continue;
          if (!["zero", "one", "two", "few", "many", "other"].includes(branch)) {
            throw new Error(`${name}: unknown plural branch ${branch}`);
          }
          if (typeof value !== "string" || !value.trim()) throw new Error(`${name}.${branch}: blank branch`);
          const signature = printfSignature(value);
          // A language may spell out a singular count instead of formatting it.
          if (Object.entries(signature).some(([position, type]) => position !== "1" || type !== expectedType)) {
            throw new Error(`${name}.${branch}: argument type or position differs from variable`);
          }
        }
      }
    } catch (error) {
      errors.push(`${key}: ${error.message}`);
    }
  }
  return errors;
}

export function protectedLiteralErrors(key, value, english) {
  const literals = [
    "gcloud auth application-default login",
    "gcloud config set project",
    "codex --version",
    "npm install -g --include=optional @openai/codex@latest",
    "kilo.access",
  ];
  const technicalTokens = [
    ...english.matchAll(/`([^`]+)`/g),
    ...english.matchAll(/\b((?:[A-Za-z][A-Za-z0-9_-]*[-_]|[A-Z]{3,}))(?=\.{3}|…)/g),
    ...english.matchAll(/\b([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)\b/g),
  ].map((match) => match[1]);
  return [...new Set([...literals, ...technicalTokens])]
    .filter((literal) => english.includes(literal) && !value.includes(literal))
    .map((literal) => `${key}: changed command or configuration literal ${literal}`);
}
