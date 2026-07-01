#!/usr/bin/env python3
"""把源模版盘转成 bundle detail 盘。
用法: gen-detail.py <源json> <ident> <src标注> [--out 路径]
- 源可以是 integrations 的 board dict, 也可以是 UI 导出格式
- 清掉写死的数字 datasourceValue -> 0 占位; 变量引用(字符串)不动
- 顶层只保留 name/ident/tags/note/configs
"""
import json, sys, argparse

def deep_zero_dsv(node):
    if isinstance(node, dict):
        if isinstance(node.get("datasourceValue"), (int, float)) and not isinstance(node.get("datasourceValue"), bool):
            node["datasourceValue"] = 0
        for v in node.values(): deep_zero_dsv(v)
    elif isinstance(node, list):
        for v in node: deep_zero_dsv(v)

ap = argparse.ArgumentParser()
ap.add_argument("src"); ap.add_argument("ident"); ap.add_argument("srcnote")
ap.add_argument("--out")
a = ap.parse_args()

raw = json.load(open(a.src))
obj = raw[0] if isinstance(raw, list) else raw
cfg = obj.get("configs")
if isinstance(cfg, str): cfg = json.loads(cfg)
deep_zero_dsv(cfg)

out = {
    "name": obj.get("name") or a.ident,
    "ident": a.ident,
    "tags": "managed-by-bundle",
    "note": f"bundle-version: 1 | src: {a.srcnote}",
    "configs": cfg,
}
path = a.out or f"deploy/single-node/dashboards/details/{a.ident}.json"
json.dump(out, open(path, "w"), ensure_ascii=False, indent=2)
print(f"✅ {path}  (vars: {[v.get('name') for v in cfg.get('var',[])]})")
