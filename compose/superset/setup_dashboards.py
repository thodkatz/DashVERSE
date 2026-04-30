"""
Provision DashVERSE dashboards in Superset.

Equivalent of ansible/playbooks/configure_superset.yml. Creates the database
connection, datasets, charts, dashboards, then wires charts into dashboards
and grants the Public role read-only access via direct SQL on the Superset
metadata database (which is the same Postgres instance).
"""
from __future__ import annotations

import json
import os
import sys
import time
from typing import Any

import psycopg2
import requests

SUPERSET_URL = os.environ["SUPERSET_URL"].rstrip("/")
SUPERSET_API = f"{SUPERSET_URL}/api/v1"
USERNAME = os.environ["SUPERSET_USERNAME"]
PASSWORD = os.environ["SUPERSET_PASSWORD"]

DATABASE_NAME = "DashVERSE"
DB_HOST = os.environ["DATABASE_HOST"]
DB_PORT = int(os.environ["DATABASE_PORT"])
DB_NAME = os.environ["DATABASE_DB"]
DB_USER = os.environ["DATABASE_USER"]
DB_PASSWORD = os.environ["DATABASE_PASSWORD"]
DB_SCHEMA = os.environ.get("DATABASE_SCHEMA", "api")

DASHBOARDS = [
    ("Policy Maker", "policy-maker"),
    ("Principal Investigator", "principal-investigator"),
    ("Research Software Engineer", "research-software-engineer"),
    ("Researcher Who Codes", "researcher-who-codes"),
    ("Trainer", "trainer"),
]

DATASET_TABLES = [
    "dimensions", "indicators", "software", "assessment_raw",
    "assessment_summary", "dimension_coverage", "indicator_results",
    "software_quality_scores", "assessment_trends", "common_issues",
    "assessments_detailed", "checks_detailed", "software_languages",
]


def _count(sql_expr: str) -> dict:
    return {"label": "count", "expressionType": "SQL", "sqlExpression": sql_expr}


def _sum(col: str, label: str | None = None) -> dict:
    return {
        "label": label or col,
        "expressionType": "SIMPLE",
        "column": {"column_name": col},
        "aggregate": "SUM",
    }


def _avg(col: str, label: str | None = None) -> dict:
    return {
        "label": label or col,
        "expressionType": "SIMPLE",
        "column": {"column_name": col},
        "aggregate": "AVG",
    }


def big_number(metric: dict, subheader: str) -> dict:
    return {
        "viz_type": "big_number_total",
        "params": {
            "metric": metric,
            "header_font_size": 0.4,
            "subheader_font_size": 0.15,
            "subheader": subheader,
        },
    }


def pie(groupby: str, metric: dict, donut: bool = False) -> dict:
    p = {
        "groupby": [groupby],
        "metric": metric,
        "color_scheme": "supersetColors",
        "show_labels": True,
        "show_legend": True,
    }
    if donut:
        p["donut"] = True
        p["innerRadius"] = 40
    return {"viz_type": "pie", "params": p}


def dist_bar(groupby: str, metric: dict, row_limit: int = 20, show_value: bool = False, y_fmt: str | None = None) -> dict:
    p = {
        "groupby": [groupby],
        "metrics": [metric],
        "color_scheme": "supersetColors",
        "row_limit": row_limit,
    }
    if show_value:
        p["show_bar_value"] = True
    if y_fmt:
        p["y_axis_format"] = y_fmt
    return {"viz_type": "dist_bar", "params": p}


def timeseries(metric: dict) -> dict:
    return {
        "viz_type": "echarts_timeseries_line",
        "params": {
            "x_axis": "month",
            "metrics": [metric],
            "color_scheme": "supersetColors",
            "show_legend": True,
            "rich_tooltip": True,
        },
    }


def heatmap(x: str, y: str, metric: dict, show_values: bool = False) -> dict:
    return {
        "viz_type": "heatmap",
        "params": {
            "all_columns_x": x,
            "all_columns_y": y,
            "metric": metric,
            "linear_color_scheme": "greenOrange",
            "show_values": show_values,
        },
    }


def table(columns: list[str], order_by: list | None = None, row_limit: int = 20, table_filter: bool = False) -> dict:
    p: dict[str, Any] = {"all_columns": columns, "row_limit": row_limit}
    if order_by:
        p["order_by_cols"] = order_by
    if table_filter:
        p["table_filter"] = True
    return {"viz_type": "table", "params": p}


def gauge(metric: dict) -> dict:
    return {
        "viz_type": "gauge_chart",
        "params": {"metric": metric, "min_val": 0, "max_val": 100, "color_scheme": "supersetColors"},
    }


# Chart specs: (slice_name, dataset, viz_dict, dashboard_slug)
CHARTS: list[tuple[str, str, dict, str]] = [
    # Policy Maker
    ("Total Software Projects", "software", big_number(_count("COUNT(*)"), "Software Projects Registered"), "policy-maker"),
    ("Total Assessments", "assessments_detailed", big_number(_count("COUNT(*)"), "Assessments Completed"), "policy-maker"),
    ("Assessment Activity Over Time", "assessment_trends", timeseries(_sum("assessments")), "policy-maker"),
    ("Quality by Software", "checks_detailed", dist_bar("software_name", _count("COUNT(*)"), row_limit=20), "policy-maker"),
    ("Compliance Heatmap", "checks_detailed", heatmap("dimension_name", "software_name", _count("COUNT(*)")), "policy-maker"),
    ("Dimension Coverage", "dimension_coverage", pie("dimension_name", _sum("total_checks"), donut=True), "policy-maker"),
    ("Quality Dimension Profile", "dimension_coverage", pie("dimension_name", _sum("passed")), "policy-maker"),
    ("Top Performing Software", "software_quality_scores", table(["software_name", "dimension_name", "score"], order_by=[["score", False]], row_limit=15), "policy-maker"),
    ("Pass Rate by Dimension", "dimension_coverage", dist_bar("dimension_name", _avg("pass_rate"), show_value=True, y_fmt=".1f"), "policy-maker"),
    ("Assessment Summary", "assessment_summary", table(["software_name", "assessment_count", "latest_assessment", "unique_indicators"], order_by=[["assessment_count", False]]), "policy-maker"),

    # Principal Investigator
    ("Projects Overview", "assessments_detailed", big_number(_count("COUNT(DISTINCT software_name)"), "Unique Projects Assessed"), "principal-investigator"),
    ("Quality Across Projects", "software_quality_scores", dist_bar("software_name", _avg("score"), show_value=True, y_fmt=".1f"), "principal-investigator"),
    ("Assessment Timeline", "assessment_trends", timeseries(_sum("assessments")), "principal-investigator"),
    ("Dimensions by Project", "checks_detailed", {"viz_type": "sunburst_v2", "params": {"columns": ["software_name", "dimension_name"], "metric": _count("COUNT(*)"), "color_scheme": "supersetColors"}}, "principal-investigator"),
    ("Failed Checks Requiring Action", "checks_detailed", table(["software_name", "dimension_name", "indicator_name", "status", "output"], row_limit=50, table_filter=True), "principal-investigator"),
    ("Project Health Gauge", "dimension_coverage", gauge(_avg("pass_rate")), "principal-investigator"),
    ("Check Status Distribution", "indicator_results", pie("status", _sum("occurrences"), donut=True), "principal-investigator"),
    ("Recent Assessments", "assessments_detailed", table(["software_name", "date_created", "total_checks"], order_by=[["date_created", False]]), "principal-investigator"),
    ("Quality Improvement Tracking", "assessment_trends", timeseries(_sum("assessments")), "principal-investigator"),
    ("Check Distribution Treemap", "checks_detailed", {"viz_type": "treemap_v2", "params": {"groupby": ["dimension_name", "indicator_name"], "metrics": [_count("COUNT(*)")], "color_scheme": "supersetColors"}}, "principal-investigator"),

    # Research Software Engineer
    ("Total Checks", "checks_detailed", big_number(_count("COUNT(*)"), "Total Checks Performed"), "research-software-engineer"),
    ("Pass Rate KPI", "dimension_coverage", big_number(_avg("pass_rate"), "Average Pass Rate %"), "research-software-engineer"),
    ("Technical Debt Heatmap", "software_quality_scores", heatmap("software_name", "dimension_name", _avg("score"), show_values=True), "research-software-engineer"),
    ("Check Results Pie", "checks_detailed", pie("status", _count("COUNT(*)"), donut=True), "research-software-engineer"),
    ("Coverage by Dimension", "checks_detailed", dist_bar("dimension_name", _count("COUNT(*)"), show_value=True), "research-software-engineer"),
    ("Checking Tools Usage", "checks_detailed", dist_bar("checking_software", _count("COUNT(*)"), row_limit=15, show_value=True), "research-software-engineer"),
    ("Failed Checks Detail", "checks_detailed", table(["software_name", "dimension_name", "indicator_name", "status", "output", "evidence"], row_limit=100, table_filter=True), "research-software-engineer"),
    ("Pass Rate Trend", "assessment_trends", timeseries(_sum("assessments")), "research-software-engineer"),
    ("Software by Language", "software_languages", pie("language", _count("COUNT(*)"), donut=True), "research-software-engineer"),
    ("Common Issues Bar", "common_issues", dist_bar("indicator_name", _sum("failure_count"), row_limit=15, show_value=True), "research-software-engineer"),
    ("Quality Dimensions Table", "dimensions", table(["name", "description", "status"]), "research-software-engineer"),
    ("Quality Indicators Table", "indicators", table(["name", "identifier", "description", "status"], row_limit=50), "research-software-engineer"),

    # Researcher Who Codes
    ("My Quality Score", "dimension_coverage", big_number(_avg("pass_rate"), "Average Quality Score"), "researcher-who-codes"),
    ("Check Pass Rate Gauge", "dimension_coverage", gauge(_avg("pass_rate")), "researcher-who-codes"),
    ("Quality Over Time", "assessment_trends", timeseries(_sum("assessments")), "researcher-who-codes"),
    ("My Quality Profile", "dimension_coverage", pie("dimension_name", _sum("passed")), "researcher-who-codes"),
    ("Action Items", "checks_detailed", table(["dimension_name", "indicator_name", "status", "output", "evidence"], row_limit=20, table_filter=True), "researcher-who-codes"),
    ("Indicator Results", "indicator_results", table(["indicator_name", "status", "occurrences"], order_by=[["occurrences", False]], row_limit=50), "researcher-who-codes"),
    ("Focus Areas", "common_issues", dist_bar("indicator_name", _sum("failure_count"), row_limit=10, show_value=True), "researcher-who-codes"),
    ("Top Performing Projects", "software_quality_scores", table(["software_name", "dimension_name", "score"], order_by=[["score", False]], row_limit=10), "researcher-who-codes"),
    ("Easy Improvements", "checks_detailed", table(["indicator_name", "dimension_name", "evidence"], row_limit=15, table_filter=True), "researcher-who-codes"),
    ("Checks by Status", "indicator_results", pie("status", _sum("occurrences")), "researcher-who-codes"),

    # Trainer
    ("Active Assessments", "assessments_detailed", big_number(_count("COUNT(*)"), "Total Assessments"), "trainer"),
    ("Average Quality Score", "dimension_coverage", big_number(_avg("pass_rate"), "Average Pass Rate"), "trainer"),
    ("Quality Improvement Timeline", "assessment_trends", timeseries(_sum("assessments")), "trainer"),
    ("Common Failed Checks", "common_issues", dist_bar("indicator_name", _sum("failure_count"), row_limit=15, show_value=True), "trainer"),
    ("Competency Heatmap", "software_quality_scores", heatmap("software_name", "dimension_name", _avg("score"), show_values=True), "trainer"),
    ("Activity by Topic Treemap", "checks_detailed", {"viz_type": "treemap_v2", "params": {"groupby": ["dimension_name", "indicator_name"], "metrics": [_count("COUNT(*)")], "color_scheme": "supersetColors"}}, "trainer"),
    ("Software Categories Pie", "checks_detailed", pie("dimension_name", _count("COUNT(*)"), donut=True), "trainer"),
    ("Training Effectiveness", "assessment_trends", timeseries(_sum("assessments")), "trainer"),
    ("Progress Tracking Table", "assessments_detailed", table(["software_name", "date_created", "total_checks"], order_by=[["date_created", False]], row_limit=50), "trainer"),
    ("Knowledge Gaps Sunburst", "checks_detailed", {"viz_type": "sunburst_v2", "params": {"columns": ["dimension_name", "indicator_name", "status"], "metric": _count("COUNT(*)"), "color_scheme": "supersetColors"}}, "trainer"),
    ("Topics Covered Bar", "checks_detailed", dist_bar("dimension_name", _count("COUNT(*)"), row_limit=15, show_value=True), "trainer"),
    ("High Achievers Table", "software_quality_scores", table(["software_name", "dimension_name", "score"], order_by=[["score", False]]), "trainer"),
]


def login() -> requests.Session:
    s = requests.Session()
    for attempt in range(60):
        try:
            r = s.post(
                f"{SUPERSET_API}/security/login",
                json={"username": USERNAME, "password": PASSWORD, "provider": "db"},
                timeout=10,
            )
            if r.status_code == 200:
                token = r.json()["access_token"]
                s.headers["Authorization"] = f"Bearer {token}"
                break
        except requests.RequestException:
            pass
        print(f"Waiting for Superset (attempt {attempt + 1})...")
        time.sleep(5)
    else:
        sys.exit("Superset never came up")

    s.post(f"{SUPERSET_URL}/login/", data={"username": USERNAME, "password": PASSWORD}, allow_redirects=True)
    csrf = s.get(f"{SUPERSET_API}/security/csrf_token/").json()["result"]
    s.headers["X-CSRFToken"] = csrf
    s.headers["Referer"] = SUPERSET_URL
    return s


def ensure_database(s: requests.Session) -> int:
    existing = s.get(f"{SUPERSET_API}/database/?q=(page_size:100)").json()["result"]
    for db in existing:
        if db["database_name"] == DATABASE_NAME:
            print(f"Database '{DATABASE_NAME}' exists (id={db['id']})")
            return db["id"]

    r = s.post(
        f"{SUPERSET_API}/database/",
        json={
            "database_name": DATABASE_NAME,
            "sqlalchemy_uri": f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}",
            "expose_in_sqllab": True,
            "allow_ctas": False,
            "allow_cvas": False,
            "allow_dml": False,
            "allow_run_async": True,
            "extra": json.dumps({"schemas_allowed_for_file_upload": [DB_SCHEMA]}),
        },
    )
    r.raise_for_status()
    db_id = r.json()["id"]
    print(f"Created database '{DATABASE_NAME}' (id={db_id})")
    return db_id


def ensure_datasets(s: requests.Session, db_id: int) -> dict[str, int]:
    existing = s.get(f"{SUPERSET_API}/dataset/?q=(page_size:1000)").json()["result"]
    by_name = {d["table_name"]: d["id"] for d in existing}

    for table_name in DATASET_TABLES:
        if table_name in by_name:
            continue
        r = s.post(
            f"{SUPERSET_API}/dataset/",
            json={"database": db_id, "table_name": table_name, "schema": DB_SCHEMA},
        )
        if r.status_code in (200, 201):
            by_name[table_name] = r.json()["id"]
            print(f"Created dataset '{table_name}'")
        elif r.status_code == 422:
            print(f"Dataset '{table_name}' already exists (422)")
        else:
            r.raise_for_status()

    refreshed = s.get(f"{SUPERSET_API}/dataset/?q=(page_size:1000)").json()["result"]
    return {d["table_name"]: d["id"] for d in refreshed}


def ensure_charts(s: requests.Session, dataset_ids: dict[str, int]) -> None:
    existing_names = {c["slice_name"] for c in s.get(f"{SUPERSET_API}/chart/?q=(page_size:200)").json()["result"]}

    for slice_name, dataset_table, viz, _slug in CHARTS:
        if slice_name in existing_names:
            continue
        if dataset_table not in dataset_ids:
            print(f"  skip '{slice_name}': dataset '{dataset_table}' missing")
            continue
        body = {
            "slice_name": slice_name,
            "datasource_id": dataset_ids[dataset_table],
            "datasource_type": "table",
            "viz_type": viz["viz_type"],
            "params": json.dumps(viz["params"]),
        }
        r = s.post(f"{SUPERSET_API}/chart/", json=body)
        if r.status_code in (200, 201):
            print(f"Created chart '{slice_name}'")
        else:
            print(f"  failed '{slice_name}': {r.status_code} {r.text[:200]}")


def ensure_dashboards(s: requests.Session) -> None:
    existing_slugs = {d["slug"] for d in s.get(f"{SUPERSET_API}/dashboard/?q=(page_size:100)").json()["result"]}

    for title, slug in DASHBOARDS:
        if slug in existing_slugs:
            continue
        body = {
            "dashboard_title": title,
            "slug": slug,
            "published": True,
            "json_metadata": json.dumps({
                "expanded_slices": {},
                "refresh_frequency": 0,
                "color_scheme": "supersetColors",
                "label_colors": {},
                "shared_label_colors": {},
                "cross_filters_enabled": True,
                "default_filters": "{}",
            }),
        }
        r = s.post(f"{SUPERSET_API}/dashboard/", json=body)
        if r.status_code in (200, 201):
            print(f"Created dashboard '{title}'")
        else:
            print(f"  failed dashboard '{title}': {r.status_code} {r.text[:200]}")


def link_charts_and_layout() -> None:
    """Link charts into dashboards, build position_json, grant Public role."""
    by_slug: dict[str, list[str]] = {slug: [] for _, slug in DASHBOARDS}
    for slice_name, _ds, _viz, slug in CHARTS:
        by_slug[slug].append(slice_name)

    conn = psycopg2.connect(host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD)
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            for slug, slice_names in by_slug.items():
                cur.execute("DELETE FROM dashboard_slices WHERE dashboard_id = (SELECT id FROM dashboards WHERE slug = %s)", (slug,))
                cur.execute(
                    """
                    INSERT INTO dashboard_slices (dashboard_id, slice_id)
                    SELECT d.id, s.id
                    FROM dashboards d, slices s
                    WHERE d.slug = %s AND s.slice_name = ANY(%s)
                    ON CONFLICT DO NOTHING
                    """,
                    (slug, slice_names),
                )

            cur.execute(_LAYOUT_SQL)
            cur.execute(_EXPAND_SLICES_SQL)
            cur.execute(_PUBLIC_ROLE_SQL)
            try:
                cur.execute(_PUBLIC_ROLE_DATASOURCE_ACCESS_SQL)
            except Exception as exc:
                print(f"Warning: failed to grant datasource access to Public role: {exc}")
            cur.execute(_REMOVE_PUBLIC_PERMS_SQL)
        print("Linked charts to dashboards, set layout, granted Public role.")
    finally:
        conn.close()


_LAYOUT_SQL = r"""
DO $$
DECLARE
    dash_record RECORD;
    chart_record RECORD;
    new_position_json jsonb;
    row_num INTEGER;
    col_num INTEGER;
    chart_key TEXT;
    row_key TEXT;
    chart_count INTEGER;
    grid_children jsonb;
BEGIN
    FOR dash_record IN
        SELECT id, slug FROM dashboards
        WHERE slug IN ('policy-maker', 'principal-investigator', 'research-software-engineer', 'researcher-who-codes', 'trainer')
    LOOP
        new_position_json := '{"GRID_ID": {"id": "GRID_ID", "type": "GRID", "children": [], "parents": ["ROOT_ID"]}, "ROOT_ID": {"id": "ROOT_ID", "type": "ROOT", "children": ["GRID_ID"]}, "HEADER_ID": {"id": "HEADER_ID", "type": "HEADER", "meta": {"text": "Dashboard"}}}'::jsonb;
        row_num := 1;
        col_num := 0;
        chart_count := 0;
        grid_children := '[]'::jsonb;

        FOR chart_record IN
            SELECT s.id, s.slice_name, s.viz_type
            FROM slices s
            JOIN dashboard_slices ds ON s.id = ds.slice_id
            WHERE ds.dashboard_id = dash_record.id
            ORDER BY s.id
        LOOP
            chart_count := chart_count + 1;
            chart_key := 'CHART-' || chart_count;
            row_key := 'ROW-' || row_num;

            IF col_num = 0 THEN
                new_position_json := jsonb_set(new_position_json, ARRAY[row_key], jsonb_build_object(
                    'id', row_key,
                    'type', 'ROW',
                    'meta', jsonb_build_object('background', 'BACKGROUND_TRANSPARENT'),
                    'parents', jsonb_build_array('ROOT_ID', 'GRID_ID'),
                    'children', '[]'::jsonb
                ));
                grid_children := grid_children || to_jsonb(row_key);
            END IF;

            new_position_json := jsonb_set(new_position_json, ARRAY[chart_key], jsonb_build_object(
                'id', chart_key,
                'type', 'CHART',
                'meta', jsonb_build_object(
                    'chartId', chart_record.id,
                    'sliceName', chart_record.slice_name,
                    'width', 6,
                    'height', CASE WHEN chart_record.viz_type = 'big_number_total' THEN 35 ELSE 50 END
                ),
                'parents', jsonb_build_array('ROOT_ID', 'GRID_ID', row_key),
                'children', '[]'::jsonb
            ));

            new_position_json := jsonb_set(
                new_position_json,
                ARRAY[row_key, 'children'],
                (new_position_json->row_key->'children') || to_jsonb(chart_key)
            );

            col_num := col_num + 1;
            IF col_num >= 2 THEN
                col_num := 0;
                row_num := row_num + 1;
            END IF;
        END LOOP;

        new_position_json := jsonb_set(new_position_json, ARRAY['GRID_ID', 'children'], grid_children);
        UPDATE dashboards SET position_json = new_position_json::text WHERE id = dash_record.id;
    END LOOP;
END;
$$;
"""

_EXPAND_SLICES_SQL = """
UPDATE dashboards
SET json_metadata = jsonb_set(
    COALESCE(json_metadata::jsonb, '{}'::jsonb),
    '{expanded_slices}',
    (SELECT COALESCE(jsonb_object_agg(s.id::text, true), '{}'::jsonb)
     FROM slices s
     JOIN dashboard_slices ds ON s.id = ds.slice_id
     WHERE ds.dashboard_id = dashboards.id)
)::text
WHERE slug IN ('policy-maker', 'principal-investigator', 'research-software-engineer', 'researcher-who-codes', 'trainer');
"""

_PUBLIC_ROLE_SQL = """
INSERT INTO dashboard_roles (id, role_id, dashboard_id)
SELECT nextval('dashboard_roles_id_seq'), r.id, d.id
FROM ab_role r, dashboards d
WHERE r.name = 'Public'
  AND d.slug IN ('policy-maker', 'principal-investigator', 'research-software-engineer', 'researcher-who-codes', 'trainer')
ON CONFLICT DO NOTHING;
"""

_PUBLIC_ROLE_DATASOURCE_ACCESS_SQL = """
INSERT INTO ab_permission_view_role (permission_view_id, role_id)
SELECT pv.id, r.id
FROM ab_role r
JOIN ab_permission p ON p.name = 'datasource_access'
JOIN tables t ON true
JOIN ab_view_menu vm ON vm.name = t.perm
JOIN ab_permission_view pv ON pv.permission_id = p.id AND pv.view_menu_id = vm.id
WHERE r.name = 'Public'
  AND t.schema = 'api'
ON CONFLICT DO NOTHING;
"""

_REMOVE_PUBLIC_PERMS_SQL = """
DELETE FROM ab_permission_view_role
WHERE role_id = (SELECT id FROM ab_role WHERE name = 'Public')
  AND permission_view_id IN (
    SELECT pv.id FROM ab_permission_view pv
    JOIN ab_permission p ON pv.permission_id = p.id
    JOIN ab_view_menu vm ON pv.view_menu_id = vm.id
    WHERE (p.name = 'can_edit' AND vm.name = 'Chart')
       OR (p.name = 'can_explore' AND vm.name = 'Superset')
       OR (p.name = 'can_view_query' AND vm.name = 'Dashboard')
       OR (p.name = 'can_view_chart_as_table' AND vm.name = 'Dashboard')
  );
"""


def main() -> None:
    s = login()
    db_id = ensure_database(s)
    dataset_ids = ensure_datasets(s, db_id)
    ensure_charts(s, dataset_ids)
    ensure_dashboards(s)
    link_charts_and_layout()
    print("Done.")


if __name__ == "__main__":
    main()
