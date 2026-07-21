# CLAUDE.md — GitHub Pages Public Deployment

## Project Overview
- Jekyll static site, publicly hosted on GitHub Pages.
- This is a user site (repo `adityavarma1234.github.io`), so it is served at the
  domain root — not under a `/reponame/` subpath.
- Production Target URL: https://adityavarma1234.github.io/

## Build & Development Commands
- Install dependencies: `bundle install`
- Local dev server: `bundle exec jekyll serve` (serves at http://localhost:4000)
- Build site: `bundle exec jekyll build` (outputs to `_site/`)

## PATHING GUIDELINES
Because this is a user/organization GitHub Pages site, it is served from the
domain root, so root-relative paths are correct and required:

1. **Use root-absolute paths**: `/css/main.css`, `/about`, `/assets/foo.jpg`, etc.
   These resolve correctly since the site lives at the domain root.
2. **Do not** prefix paths with a repo name or use a `<base>` tag — that guidance
   only applies to *project* pages (repos named something other than
   `<user>.github.io`), which is not the case here.

## Notes
- No client-side router is used — this is server-rendered static HTML from
  Jekyll, so there is no SPA routing/refresh concern to account for.
