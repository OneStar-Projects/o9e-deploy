#!/usr/bin/env python3
# 校验总览盘符合契约:ident/note 就位、dsv 全占位、6 分类链接正确
import json, sys
d = json.load(open("deploy/single-node/dashboards/resource-inventory-overview.json"))
errs = []
if d.get("ident") != "resource-overview": errs.append(f"ident应为resource-overview, 实际{d.get('ident')!r}")
if "managed-by-bundle" not in (d.get("tags") or ""): errs.append("tags缺managed-by-bundle")
if not (d.get("note") or "").startswith("bundle-version:"): errs.append("note缺bundle-version")
WANT = {
 "主机": "/dashboards/host-detail?ident=${__field.labels.ident}",
 "网络设备": "/dashboards/net-detail?ipadd=${__field.labels.LocalIP}&jieru=1&sys_name=all",
 "数据库": "/dashboards/db-${__field.labels.dbtype}?instance=${__field.labels.instance}",
 "中间件": "/dashboards/mw-${__field.labels.svctype}?instance=${__field.labels.instance}",
 "容器": "/dashboards/container-${__field.labels.ctype}?ident=${__field.labels.ident}",
 "应用": "/dashboards/app-detail?instance=${__field.labels.instance}",
 "网络专线": "/dashboards/leased-line-detail?line=${__field.labels.line}",
}
for p in d["configs"]["panels"]:
    if p.get("type") != "table": continue
    if p.get("datasourceValue") != 0: errs.append(f"表[{p.get('name')}] dsv应为占位0, 实际{p.get('datasourceValue')}")
    nm = p.get("name","")
    for key, url in WANT.items():
        if key in nm:
            got = (p["custom"].get("links") or [{}])[0].get("url")
            if got != url: errs.append(f"表[{nm}] 链接不符\n  期望 {url}\n  实际 {got}")
if errs:
    print("❌ FAIL"); [print(" -", e) for e in errs]; sys.exit(1)
print("✅ 总览盘契约校验通过")
