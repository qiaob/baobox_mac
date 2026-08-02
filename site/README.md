# 官网

单页静态站，零构建、零依赖、零外链资源（字体走系统字族，图标是内联 SVG）。

```
site/
├── index.html    # 全部内容与样式都在这一个文件里
├── favicon.svg
└── _headers      # Cloudflare Pages 的响应头
```

## 部署到 Cloudflare Pages

Pages → Create project → Connect to Git → 选本仓库，然后：

| 设置项 | 值 |
|---|---|
| Framework preset | None |
| Build command | *（留空）* |
| Build output directory | `site` |
| Root directory | *（留空，即仓库根）* |

之后 push 到 `main` 即自动部署。绑自定义域在 Pages 项目的 Custom domains 里加。

## 改内容

`index.html` 顶部是配色令牌，与 App 共用一套（同 `docs/design/ui-design-v1.html`），
改一处两边都跟着变。页面自适应浅色/深色，跟随访问者的系统设置。

## 待替换的占位

- **App Store 链接**：`index.html` 里两处 `https://apps.apple.com/app/baobox/id000000000`，
  上架后换成真实 ID。
- **canonical / og:url**：现在写的是 `https://baobox.app/`，换成实际域名。
- **社交预览图**：还没有。要的话准备一张 1200×630 的 PNG 放进 `site/`，
  再在 `<head>` 里补 `og:image` 与 `twitter:image`。
