// GET <url> and report every command/skill entry whose name matches <name>.
const [, , url, wanted] = process.argv;
const flat = (s) => String(s ?? "").replace(/[\t\r\n]+/g, " ").trim();

fetch(url)
  .then((r) => r.json())
  .then((list) => {
    const entries = Array.isArray(list) ? list : [];
    const matches = entries.filter((e) => e && e.name === wanted);
    for (const m of matches) {
      console.log(`MATCH\t${flat(m.source)}\t${flat(m.description)}`);
    }
    console.log(`TOTAL\t${entries.length}`);
    console.log(`NAMES\t${entries.map((e) => flat(e && e.name)).join(",")}`);
    process.exit(matches.length ? 0 : 1);
  })
  .catch((e) => {
    console.log(`ERROR\t${flat(e && e.message)}`);
    process.exit(2);
  });
