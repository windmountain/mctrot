// Regenerates live.schema.json from src/live.ts: `npm run schema`.
import { writeFileSync } from "node:fs";
import { liveJsonSchema } from "./live.ts";

const path = new URL("../live.schema.json", import.meta.url);
writeFileSync(path, JSON.stringify(liveJsonSchema(), null, 2) + "\n");
console.log(`wrote ${path.pathname}`);
