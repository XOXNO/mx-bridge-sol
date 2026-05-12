// ESLint v9+ flat config. Replaces the legacy .eslintrc.yaml.
// Run via `yarn lint:ts` (no --config flag needed; ESLint auto-discovers this file).

import js from "@eslint/js";
import tseslint from "typescript-eslint";
import prettier from "eslint-config-prettier";

export default [
  // Global ignores (replaces .eslintignore).
  {
    ignores: [
      ".yarn/**",
      "**/artifacts/**",
      "**/build/**",
      "**/cache/**",
      "**/cache_forge/**",
      "**/coverage/**",
      "**/dist/**",
      "**/node_modules/**",
      "**/typechain/**",
      "**/typechain-types/**",
      "**/types/ethers-contracts/**",
      "**/out/**",
      "lib/**",
      ".openzeppelin/**",
      "*.env",
      "*.log",
      "*.tsbuildinfo",
      ".pnp.*",
      "coverage.json",
      "npm-debug.log*",
      "yarn-debug.log*",
      "yarn-error.log*",
      // The config file itself; tseslint type-aware rules don't have a tsconfig for it.
      "eslint.config.mjs",
    ],
  },

  // Base JS rules apply to everything that survives the ignore list.
  js.configs.recommended,

  // TypeScript rules + parser, scoped to *.ts files only.
  ...tseslint.configs.recommended.map((cfg) => ({
    ...cfg,
    files: ["**/*.ts"],
  })),

  // Type-aware overrides for our TS sources. parserOptions.project enables
  // rules like @typescript-eslint/no-floating-promises that need type info.
  {
    files: ["**/*.ts"],
    languageOptions: {
      parserOptions: {
        project: "tsconfig.json",
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      "@typescript-eslint/no-floating-promises": [
        "error",
        { ignoreIIFE: true, ignoreVoid: true },
      ],
      "@typescript-eslint/no-inferrable-types": "off",
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],
    },
  },

  // Prettier compat last to disable conflicting style rules.
  prettier,
];
