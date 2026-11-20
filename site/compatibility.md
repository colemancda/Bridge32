---
title: Compatibility
permalink: /compatibility/
---

# Compatibility

Each app is at the level of its newest report. Reports come from the project's pull requests, commits and README; an app's page lists them all.

<dl class="levels">
{%- for level in site.data.levels %}
  <dt><span class="level level-{{ level.level }}"><span class="level-number">{{ level.level }}</span> · {{ level.name }}</span></dt>
  <dd>{{ level.description }}</dd>
{%- endfor %}
</dl>

{% assign platforms = "ios,macos" | split: "," -%}
{%- for platform in platforms %}
{%- assign apps = site.apps | where: "platform", platform | sort_natural: "name" %}
<h2 id="{{ platform }}">{% if platform == "ios" %}iOS apps{% else %}Mac apps{% endif %}</h2>

<div class="table-wrap">
<table>
  <thead>
    <tr><th>Name</th><th>Kind</th><th>Guest</th><th>Level</th><th>Last tested</th><th>Notes</th><th>Screenshot</th></tr>
  </thead>
  <tbody>
  {%- for app in apps %}
    {%- assign newest = app.reports | last %}
    {%- assign newest_level = site.data.levels | where: "level", newest.level | first %}
    {%- assign guests = app.reports | map: "guest" | compact | uniq %}
    <tr>
      <td><a href="{{ app.url | relative_url }}">{{ app.name | escape }}</a></td>
      <td>{{ app.kind | capitalize }}</td>
      <td class="nowrap">{% if guests.size > 0 %}{{ guests | join: ", " }}{% else %}–{% endif %}</td>
      <td><span class="level level-{{ newest.level }}"><span class="level-number">{{ newest.level }}</span> · {{ newest_level.name }}</span></td>
      <td class="nowrap">
        {%- if newest.source == "pr" -%}
        <a href="https://github.com/colemancda/Bridge32/pull/{{ newest.pr }}">{{ newest.date | date: "%Y-%m-%d" }}</a>
        {%- else -%}
        <a href="https://github.com/colemancda/Bridge32/commit/{{ newest.bridge32 }}">{{ newest.date | date: "%Y-%m-%d" }}</a>
        {%- endif -%}
      </td>
      <td>{{ newest.notes | escape }}</td>
      <td>
        {%- if newest.screenshots -%}
        {%- assign shot = newest.screenshots | first -%}
        <a href="{{ app.url | relative_url }}"><img src="{{ shot.url }}" alt="{{ shot.caption | escape }}" width="160" loading="lazy"></a>
        {%- endif -%}
      </td>
    </tr>
  {%- endfor %}
  </tbody>
</table>
</div>
{%- endfor %}
