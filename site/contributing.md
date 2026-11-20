---
title: Contributing
permalink: /contributing/
---

# Adding a compatibility report

Every app has one Markdown file in [`site/_apps`](https://github.com/colemancda/Bridge32/tree/main/site/_apps). Its YAML front matter holds the app and its reports; GitHub shows it as a table when the file is opened, and the site builds the app's page and its row in the [compatibility table]({{ '/compatibility/' | relative_url }}) from it. To add a report, add an entry to the end of the app's `reports`, or add a file for a new app, and open a pull request.

## The file

```markdown
---
name: Doom 3
platform: macos          # ios | macos
kind: game               # app | game
developer: id Software   # only if the evidence states it or it is unambiguous
reports:
  - date: 2026-11-19     # the PR's merge date, or the commit's date
    bridge32: "0a1b2c3d" # the merge commit or the commit, 8 characters, always quoted
    pr: 19               # the pull request it rests on, or that holds its screenshots
    guest: i386          # armv6 | armv7 | i386 | ppc
    app_version: "1.3.1" # only if stated, always quoted
    level: 3
    source: pr           # pr | commit | readme | screenshot: what the level rests on
    notes: Reaches its main menu.
    screenshots:
      - url: https://github.com/user-attachments/assets/00000000-0000-0000-0000-000000000000
        caption: Main menu
---

Optional notes in Markdown: known problems, the `make-app.sh` options or
`B32_*` settings the app needs, guest libraries it requires. Leave the
body empty if the evidence says nothing more than the reports do.
```

- The file is named for the app: its name in lowercase ASCII, with every run of other characters made a hyphen and a Roman numeral written as a number. `Age of Empires III` is `age-of-empires-3.md`, `Call of Duty: Zombies` is `call-of-duty-zombies.md`.
- `name`, `platform`, `kind` and `reports` are required; so are each report's `date`, `bridge32`, `level`, `source` and `notes`, and each screenshot's `url` and `caption`. Leave out a field you can't back with a pull request, a commit or the README rather than guess it.
- Reports go in date order, oldest first. An app's level is its newest report's level.
- `notes` is one or two plain sentences, in the present tense, saying how far the app gets and what is known to be wrong.
- Don't add `layout`, `title` or `permalink`; the site's configuration supplies them.

### Quoting

- `bridge32` and `app_version` are always quoted, so YAML never reads a commit such as `12345678` or a version such as `1.50` as a number.
- Quote any value that contains `: ` or starts with a quote, `#`, `[`, `{`, `*`, `&`, `!`, `|`, `>`, `@` or a backtick.

## Levels

| Level | Name | Assign when the evidence says |
| --- | --- | --- |
| 1 | Loads | starts, then stops or crashes; "load", "through loading", "start-up" |
| 2 | First screen | splash, title screen, launcher, welcome window, dialogs before a menu |
| 3 | Main content, major issues | a main menu, an editor window or a level reached, with stated problems or no claim of being usable |
| 4 | Usable | "play", "playable", or an app's main function shown working with only small issues named |
| 5 | Complete | the evidence states that everything tested works |

Use the lowest level the evidence supports. A report that says an app runs, with no milestone, is level 3; level 5 needs an explicit statement that everything tested works. A screenshot raises a level only to what it plainly shows.

## Screenshots

Screenshots are never stored in this repository. Attach the image to a pull request in this repository, and copy its URL from there into the report exactly as it appears. Only these forms are accepted:

- `https://github.com/user-attachments/assets/<uuid>`
- `https://github.com/colemancda/Bridge32/assets/<id>/<uuid>`
- `https://user-images.githubusercontent.com/<id>/<name>`

A report with screenshots needs its `pr`. For a report that rests on a commit or the README, `pr` is the pull request its screenshots are attached to, and the report still links its commit. Don't attach an image that shows an email address, an account name, a street address, a phone number, a precise location, a device serial or message content.

## Checking and building

The check script needs only Ruby:

```sh
ruby tools/compatibility-check.rb
```

To build the site and look at it:

```sh
cd site
bundle install
bundle exec jekyll serve
```

Then open <http://localhost:4000/Bridge32/>. Pull requests that change `site/` run the same check and build.
