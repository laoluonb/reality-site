# 山间手记 / REALITY 自建目标网站

一个有实际内容的静态网站，配套 Debian / Ubuntu 一键部署脚本。
部署后网站在 `127.0.0.1:8443` 提供 HTTPS，443 留给现有的 REALITY。

本项目不安装 Xray，不自动修改代理配置，也不保证规避识别或封锁。

## 准备条件

- Debian 12+ 或 Ubuntu 22.04+，使用 systemd，有 root / sudo 权限。
- 一个你拥有的真实域名，例如 `notes.your-domain.com`。
- DNS A 记录直接指向服务器；如果设置了 AAAA，它也必须正确指向该服务器。
- 不开启 Cloudflare 橙云等 CDN 代理。
- 公网 TCP 80 可访问，用于 Let's Encrypt HTTP-01 验证和长期续期；公网 TCP 443 留给 REALITY。
- 本机 8443 空闲。网站只监听回环地址，不需要在安全组开放 8443。
- 安装使用 apt 安装 nginx、certbot 等依赖，请先处理其他程序对 80 的占用。
- 脚本会向 Let's Encrypt 注册账户并接受其服务条款，可通过 `--email` 指定通知邮箱。

## 方式一：下载完整项目后安装

把项目上传到 GitHub，在服务器下载项目 ZIP、解压并进入项目目录：

```bash
sudo bash install.sh notes.your-domain.com --email you@your-domain.com
```

不传 `--repo` 时，脚本使用它旁边的 `site/`，适合本地上传或 ZIP 部署。

## 方式二：从 GitHub 一条命令安装

本项目仓库为 `laoluonb/reality-site`，默认分支为 `main`。
下面只需替换域名和邮箱。命令分步检查下载是否成功，再执行。
如果使用你自己 fork 的仓库，再把两处 `laoluonb/reality-site` 都换成你的仓库名称。

```bash
curl -fL --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/laoluonb/reality-site/main/install.sh \
  -o /tmp/reality-site-install.sh \
  && sudo bash /tmp/reality-site-install.sh notes.your-domain.com \
  --email you@your-domain.com --repo laoluonb/reality-site
```

可用 `--ref` 指定某个提交或标签。若不用 `main`，安装脚本的下载 URL 和 `--ref` 要保持一致。
私有仓库不支持这种免登录拉取方式。

## 部署后还要配置 REALITY

在现有 Xray 入站的 `streamSettings.realitySettings` 中，只调整下面这两个字段：

```json
{
  "target": "127.0.0.1:8443",
  "serverNames": ["notes.your-domain.com"]
}
```

这只是相关字段片段，不是完整 Xray 配置。旧版 Xray 使用 `dest` 代替 `target`，按你现有配置的版本使用其中一个。
保留原有 UUID、私钥、shortIds、flow 等设置；入站监听公网 TCP 443；客户端 SNI 填同一个域名。
修改后先检查 Xray 配置，再重启对应的服务。

ArgoSBX 生成器里的“Reality 域名”填写该域名。
检查**实际生成**的配置：如果目标仍是 `域名:443`，必须改为 `127.0.0.1:8443`。
只改“Reality 域名”不会自动发现网站的内部端口。
此脚本不修改 ArgoSBX 模板；面板重装或重新生成配置后，要再次核对目标地址。

## 验证

安装器会验证本地 HTTPS 证书、TLS 1.3 和 HTTP/2。
也可手动执行：

```bash
curl --noproxy '*' --resolve notes.your-domain.com:8443:127.0.0.1 \
  https://notes.your-domain.com:8443/
sudo certbot renew --dry-run
```

REALITY 配好后，用普通浏览器打开 `https://notes.your-domain.com`，应能看到网站；
代理客户端使用原有凭据和相同 SNI 测试连接。
未配置 REALITY 前，公网 443 打不开属于预期情况，脚本不会自行占用 443。

如果证书申请失败，优先检查 A/AAAA、CDN 代理、系统防火墙和云安全组的 TCP 80。
不要把 `target` 写成解析回本机的 `域名:443`，否则会指回 REALITY 自己。

## 维护

- 网站目录：`/var/www/reality-site/public`。
- Nginx 配置：`/etc/nginx/sites-available/reality-site.conf`。
- 证书目录：`/etc/letsencrypt/live/你的域名/`。
- 自动续期：`certbot.timer`；续期成功后自动检查并重载 Nginx。
- 在 GitHub 更新网站后，重新执行同一安装命令即可拉取更新；不要频繁重复申请证书。
- 一个服务器上的本脚本只管理一个域名。已有其他 Nginx 站点不会被删除；检测到明显域名或端口冲突时停止。
- 安装失败会恢复之前受本脚本管理的 Nginx 配置。已安装的软件、网站文件和已申请的证书会保留。
- 没有自动修改系统防火墙或云安全组。

网站无外部字体、脚本或运行时依赖。图片保存在仓库内。
内容和样式分别在 `site/index.html` 和 `site/styles.css` 中。

## 图片与许可

网站照片来自 Unsplash：
`https://images.unsplash.com/photo-1472396961693-142e6e269027`
遵循 Unsplash License：https://unsplash.com/license 。
仓库中的 MIT 许可覆盖代码与原创文字，不替代照片的原始许可。

## 参考

- REALITY 官方：https://github.com/XTLS/REALITY
- Xray 配置：https://xtls.github.io/config/transport.html
- Certbot：https://eff-certbot.readthedocs.io/en/stable/using.html
