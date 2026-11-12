// Minimal Grafana dashboard helpers in plain jsonnet.
//
// This mixin deliberately does not vendor grafonnet: the dashboards only need
// a handful of panel types, and keeping the dependency count at zero means
// `make render` works with nothing but a jsonnet binary.
{
  local ds = { type: 'prometheus', uid: '${datasource}' },

  datasource:: ds,

  // ---- template variables -------------------------------------------------

  datasourceVar:: {
    name: 'datasource',
    label: 'Data source',
    type: 'datasource',
    query: 'prometheus',
    current: {},
    hide: 0,
    refresh: 1,
    regex: '',
  },

  queryVar(name, label, query, multi=true, includeAll=true, allValue='.*'):: {
    name: name,
    label: label,
    type: 'query',
    datasource: ds,
    query: { query: query, refId: 'StandardVariableQuery' },
    definition: query,
    current: {},
    hide: 0,
    refresh: 2,
    sort: 1,
    multi: multi,
    includeAll: includeAll,
    [if includeAll then 'allValue']: allValue,
    regex: '',
  },

  customVar(name, label, values, default):: {
    name: name,
    label: label,
    type: 'custom',
    query: std.join(',', values),
    current: { selected: true, text: default, value: default },
    options: [{ selected: v == default, text: v, value: v } for v in values],
    hide: 0,
    multi: false,
    includeAll: false,
  },

  // ---- targets ------------------------------------------------------------

  target(expr, legend='', instant=false, format='time_series'):: {
    datasource: ds,
    expr: std.stripChars(expr, '\n '),
    legendFormat: legend,
    [if instant then 'instant']: true,
    [if instant then 'range']: false,
    [if format != 'time_series' then 'format']: format,
  },

  local withRefIds(targets) = [
    targets[i] { refId: std.char(std.codepoint('A') + i) }
    for i in std.range(0, std.length(targets) - 1)
  ],

  // ---- panels -------------------------------------------------------------

  local thresholdSteps(steps) = {
    mode: 'absolute',
    steps: [{ color: s[1], value: s[0] } for s in steps],
  },

  timeseries(title, description, unit, targets, stack=false, min=null, max=null, decimals=null, fill=10):: {
    type: 'timeseries',
    title: title,
    description: description,
    datasource: ds,
    targets: withRefIds(targets),
    fieldConfig: {
      defaults: {
        unit: unit,
        [if min != null then 'min']: min,
        [if max != null then 'max']: max,
        [if decimals != null then 'decimals']: decimals,
        color: { mode: 'palette-classic' },
        custom: {
          drawStyle: 'line',
          lineInterpolation: 'linear',
          lineWidth: 1,
          fillOpacity: if stack then 40 else fill,
          gradientMode: 'none',
          showPoints: 'never',
          spanNulls: false,
          stacking: { group: 'A', mode: if stack then 'normal' else 'none' },
          axisPlacement: 'auto',
          thresholdsStyle: { mode: 'off' },
        },
      },
      overrides: [],
    },
    options: {
      legend: { displayMode: 'table', placement: 'bottom', showLegend: true, calcs: ['mean', 'max', 'lastNotNull'] },
      tooltip: { mode: 'multi', sort: 'desc' },
    },
  },

  stat(title, description, unit, targets, steps=[[null, 'text']], decimals=null, graph=true, textMode='auto'):: {
    type: 'stat',
    title: title,
    description: description,
    datasource: ds,
    targets: withRefIds(targets),
    fieldConfig: {
      defaults: {
        unit: unit,
        [if decimals != null then 'decimals']: decimals,
        color: { mode: 'thresholds' },
        thresholds: thresholdSteps(steps),
        noValue: 'n/a',
      },
      overrides: [],
    },
    options: {
      colorMode: 'value',
      graphMode: if graph then 'area' else 'none',
      justifyMode: 'auto',
      orientation: 'auto',
      textMode: textMode,
      reduceOptions: { calcs: ['lastNotNull'], fields: '', values: false },
    },
  },

  heatmap(title, description, unit, expr):: {
    type: 'heatmap',
    title: title,
    description: description,
    datasource: ds,
    targets: withRefIds([$.target(expr, '{{le}}', format='heatmap')]),
    fieldConfig: { defaults: { custom: { hideFrom: { legend: false, tooltip: false, viz: false } } }, overrides: [] },
    options: {
      calculate: false,
      cellGap: 1,
      color: { mode: 'scheme', scheme: 'Blues', steps: 64, exponent: 0.5, fill: 'dark-orange', reverse: false },
      yAxis: { axisPlacement: 'left', unit: unit, reverse: false },
      cellValues: { unit: 'short' },
      legend: { show: true },
      tooltip: { mode: 'single', yHistogram: true, showColorScale: false },
      filterValues: { le: 1e-9 },
      showValue: 'never',
    },
  },

  // A table fed by instant queries: one value column per target, merged on
  // their shared labels.
  table(title, description, columns):: {
    type: 'table',
    title: title,
    description: description,
    datasource: ds,
    targets: withRefIds([$.target(col.expr, instant=true, format='table') for col in columns]),
    transformations: [
      { id: 'merge', options: {} },
      {
        id: 'organize',
        options: {
          excludeByName: { Time: true },
          renameByName: {
            ['Value #' + std.char(std.codepoint('A') + i)]: columns[i].name
            for i in std.range(0, std.length(columns) - 1)
          },
        },
      },
    ],
    fieldConfig: {
      defaults: { custom: { align: 'auto', cellOptions: { type: 'auto' } } },
      overrides: [
        {
          matcher: { id: 'byName', options: col.name },
          properties: [{ id: 'unit', value: col.unit }] +
                      (if std.objectHas(col, 'decimals') then [{ id: 'decimals', value: col.decimals }] else []),
        }
        for col in columns
      ],
    },
    options: { showHeader: true, cellHeight: 'sm', footer: { show: false } },
  },

  text(title, content):: {
    type: 'text',
    title: title,
    description: '',
    options: { mode: 'markdown', content: content },
  },

  // ---- layout -------------------------------------------------------------

  // rows: [{ title, collapsed (optional), height (optional), panels: [panel { w:: N }] }]
  // Panels are laid out left to right and wrap at 24 columns.
  local layout(rows) =
    local step(state, row) =
      local h = if std.objectHas(row, 'height') then row.height else 8;
      local header = {
        type: 'row',
        title: row.title,
        collapsed: false,
        gridPos: { h: 1, w: 24, x: 0, y: state.y },
        panels: [],
      };
      local place(s, p) =
        local w = if std.objectHasAll(p, 'w') then p.w else 12;
        local wrap = s.x + w > 24;
        local x = if wrap then 0 else s.x;
        local y = if wrap then s.y + h else s.y;
        {
          x: x + w,
          y: y,
          out: s.out + [p { gridPos: { h: h, w: w, x: x, y: y } }],
        };
      local placed = std.foldl(place, row.panels, { x: 0, y: state.y + 1, out: [] });
      {
        y: placed.y + h,
        panels: state.panels + [header] + placed.out,
      };
    std.foldl(step, rows, { y: 0, panels: [] }).panels,

  local withIds(panels) = [
    panels[i] { id: i + 1 }
    for i in std.range(0, std.length(panels) - 1)
  ],

  dashboard(title, uid, description, config, variables, rows, timeFrom=null):: {
    title: title,
    uid: uid,
    description: description,
    tags: config.dashboardTags,
    schemaVersion: 39,
    version: 1,
    editable: false,
    graphTooltip: 1,
    fiscalYearStartMonth: 0,
    liveNow: false,
    timezone: 'browser',
    weekStart: '',
    refresh: config.dashboardRefresh,
    time: { from: if timeFrom != null then timeFrom else config.dashboardTimeFrom, to: 'now' },
    timepicker: { refresh_intervals: ['30s', '1m', '5m', '15m', '30m', '1h'] },
    annotations: {
      list: [
        {
          builtIn: 1,
          datasource: { type: 'grafana', uid: '-- Grafana --' },
          enable: true,
          hide: true,
          iconColor: 'rgba(0, 211, 255, 1)',
          name: 'Annotations & Alerts',
          type: 'dashboard',
        },
      ],
    },
    links: [
      {
        title: 'DACS dashboards',
        type: 'dashboards',
        tags: config.dashboardTags,
        asDropdown: true,
        includeVars: true,
        keepTime: true,
        targetBlank: false,
        icon: 'external link',
        tooltip: '',
        url: '',
      },
    ],
    templating: { list: variables },
    panels: withIds(layout(rows)),
  },
}
