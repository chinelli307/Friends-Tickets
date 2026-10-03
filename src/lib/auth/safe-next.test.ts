import { describe, expect, it } from "vitest";
import { safeNext } from "./safe-next";

const origin = "http://localhost:3000";

describe("safeNext", () => {
  it("acepta rutas relativas propias", () => {
    expect(safeNext("/", origin)).toBe("/");
    expect(safeNext("/grupos/1?a=b#c", origin)).toBe("/grupos/1?a=b#c");
  });

  it("usa / si falta o no empieza por /", () => {
    expect(safeNext(null, origin)).toBe("/");
    expect(safeNext("", origin)).toBe("/");
    expect(safeNext("grupos", origin)).toBe("/");
    expect(safeNext("https://evil.com", origin)).toBe("/");
  });

  it("rechaza URLs de otro origen", () => {
    expect(safeNext("//evil.com", origin)).toBe("/");
    expect(safeNext("/\\evil.com", origin)).toBe("/");
    expect(safeNext("/\\/evil.com", origin)).toBe("/");
  });
});
