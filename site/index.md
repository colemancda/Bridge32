---
title: Home
---

# Bridge32

Bridge32 runs 32-bit apps on Apple Silicon Macs. Their code is emulated, and every system call, C function and Objective-C message is answered by the real 64-bit frameworks on the Mac: UIKit, AppKit, Foundation, Core Graphics, OpenGL and the rest. Nothing of the original operating system is reimplemented; the bridge converts between the guest's 32-bit ABI and the host's. A wrapped app is an ordinary Mac app, with its own bundle identifier, container and Dock entry.

## Guests

| Guest | Apps | CPU emulation | Build |
| --- | --- | --- | --- |
| armv6, armv7 | iPhone OS 2 to iOS 10 apps, in a Mac Catalyst shell | dynarmic | the default |
| i386 | Intel Mac apps, in an AppKit shell | Unicorn 2 | `-DB32_GUEST_ARCH=i386` |
| PowerPC | PowerPC Mac apps, in an AppKit shell | Unicorn 2's PowerPC target | `-DB32_GUEST_ARCH=ppc` |

## Apps by level

{% assign app_count = site.apps | size -%}
The database has {{ app_count }} apps, each at the level of its newest report.

<ul class="counts">
{%- for level in site.data.levels %}
  {%- assign count = 0 %}
  {%- for app in site.apps %}
    {%- assign newest = app.reports | last %}
    {%- if newest.level == level.level %}{% assign count = count | plus: 1 %}{% endif %}
  {%- endfor %}
  <li><span class="level level-{{ level.level }}"><span class="level-number">{{ level.level }}</span> · {{ level.name }}</span> {{ count }}</li>
{%- endfor %}
</ul>

See the [compatibility table]({{ '/compatibility/' | relative_url }}) for every app and how far it gets, or [add a report]({{ '/contributing/' | relative_url }}). The source is on [GitHub](https://github.com/colemancda/Bridge32).
