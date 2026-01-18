# Contributing Guide

Thank you for considering contributing to **zig-waybar-contrib**! 🎉  
We appreciate all forms of help — whether it’s fixing bugs, improving documentation, or adding new modules.

---

## 🧑‍💻 Code Contributions

### What You Can Do
- 🐛 **Bug Fixes** — Investigate and fix issues reported by users.  
- ⚡ **Performance Improvements** — Optimize existing modules for speed or efficiency.  
- 🧩 **New Modules** — Add new metrics or integrations to expand functionality.  
- 🎨 **Code Quality** — Refactor, clean up, or improve structure and maintainability.  

### Coding Standards
- The project follows **Zig’s official style**.  
  Format your code before committing:
  ```bash
  zig fmt src/
  ```
- Keep functions small and focused.
- Use clear naming and prefer explicit over implicit.
- Avoid unnecessary allocations; prefer stack-based data when possible.
- Write idiomatic Zig — use `error` unions instead of exceptions or booleans.

---

## 🧾 Commit Message Guidelines

Use **Conventional Commits** format for clarity and consistency:
```
<scope>: <folder>(<lib>): <short summary>

<optional body>
```

Examples:
- `refactor: core(pid): isAlive() to use /proc check`
- `fix: modules(cpu): fix incorrect usage of std.fs`
- `docs: improve build instructions`

**Types:**
- `feat:` → new feature
- `fix:` → bug fix
- `refactor:` → code restructuring
- `docs:` → documentation changes
- `test:` → test-related changes
- `chore:` → maintenance or CI

---

## 🧪 Testing & Validation

Before opening a PR:
1. Build the project:
   ```bash
   zig build
   ```
2. Run the test suite:
   ```bash
   zig build test
   ```
3. Verify no formatting or linter issues:
   ```bash
   zig fmt --check src/
   ```
4. Test your module on your system (Waybar/desktop) if applicable.

---

## 🔄 Development Workflow

1. **Fork** the repository on GitHub.  
2. **Clone** your fork locally:
   ```bash
   git clone https://github.com/erffy/zig-waybar-contrib.git
   cd zig-waybar-contrib
   ```
3. **Create a new branch** for your work:
   ```bash
   git checkout -b feature/amazing-module
   ```
4. **Make your changes** and **test thoroughly**.  
5. **Commit** using proper message format.  
6. **Push** your branch:
   ```bash
   git push origin feature/amazing-module
   ```
7. **Open a Pull Request** on GitHub:
   - Describe your changes clearly.
   - Reference related issues (e.g. `Closes #42`).
   - Include screenshots if applicable.

---

## 🧩 Code Review Process

- Every PR is reviewed for clarity, correctness, and style.
- You may be asked to make small adjustments (don’t worry — that’s normal!).
- After approval, a maintainer will merge your PR into `master`.

---

## 📚 Documentation Contributions

Improving documentation is always appreciated!  
You can:
- Fix typos or improve readability.
- Add examples for existing modules.
- Clarify build or configuration steps.

---

## 💬 Questions or Suggestions

If you have questions:
- Open a [GitHub Issue](https://github.com/erffy/zig-waybar-contrib/issues)

---

## ❤️ Code of Conduct

Please be respectful and constructive.  
We follow the [Contributor Covenant](https://contributor-covenant.org/) Code of Conduct.

---

*Happy hacking and thank you for improving zig-waybar-contrib!* 🦾
