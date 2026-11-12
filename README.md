# 山间手记 / REALITY 自建目标网站

一个有实际内容的静态网站，配套 Debian / Ubuntu 一键部署脚本。
部署后网站在 `127.0.0.1:8443` 提供 HTTPS，443 留给现有的 REALITY。
直接运行 `.sh` 脚本即可进入中文菜单，按提示输入域名和邮箱。
每次安装默认随机部署一套模板，更新时保留当前模板，也可以通过菜单随机更换。

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

## 推荐：下载脚本进入菜单

在服务器执行：

```sh
curl -fL --retry 3 --retry-all-errors --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/laoluonb/reality-site/main/install.sh \
  -o reality-site.sh && sudo sh reality-site.sh
```

以 root 登录时，可省略 `sudo`。使用 `sh` 启动时，脚本会自动交给 Bash 执行。
需要已安装 Bash 和 curl。请先下载再运行，不要使用 `curl | sh`，否则无法正常进行菜单输入。
之后再次运行 `sudo sh reality-site.sh` 即可管理网站。

菜单选项：

| 选项 | 操作 |
| --- | --- |
| 1 | 安装 / 重新配置网站，提示输入域名、可选邮箱，并确认后开始 |
| 2 | 从 GitHub 更新网页，不重新申请证书 |
| 3 | 查看域名、服务状态、证书有效期、续期定时器和端口 |
| 4 | 显示需要填入 REALITY 的设置 |
| 5 | 检查本机 HTTPS 证书、TLS 1.3 和 HTTP/2 |
| 6 | 只测试该网站证书的自动续期，不强制更换正式证书 |
| 7 | 随机更换成另一套网站模板，不改证书、域名或 REALITY 设置 |
| 0 | 退出 |

现有安装可直接使用新版菜单，无需重新安装。安装或更新失败后会返回菜单。
本脚本每台服务器只管理一个域名，重新配置时不能直接覆盖成另一个域名。
菜单不会自动修改已有 REALITY 配置。

## 网站模板

| 标识 | 网站 | 内容与风格 |
| --- | --- | --- |
| `fieldnotes` | 山间手记 | 山野与行走，留白与自然摄影 |
| `architecture` | 构筑笔记 | 建筑与城市观察，黑白与砖红 |
| `garden` | 叶间日常 | 植物与四季，绿色与花色点缀 |
| `coast` | 海岸来信 | 海边生活短文，海浪照片与书信排版 |

四套模板都有完整文字、本地图片和移动端布局，无需外部字体或脚本。
随机只决定网站内容和样式，HTTPS 与 REALITY 的配置方式相同。
安装完成后会显示选中的模板，菜单 3 也能查询。
菜单 2 更新当前模板；菜单 7 从另外三套中随机选一套。
旧版本已安装的网站默认识别为山间手记，可以直接使用新菜单。
当前模板记录在 `/var/www/reality-site/template`，无需手动修改。

无交互安装时，可以用 `--template` 固定模板；不传或传 `random` 都会随机选择：

```bash
sudo bash install.sh notes.your-domain.com --template coast
```

## 可选：通过参数安装

把项目上传到 GitHub，在服务器下载项目 ZIP、解压并进入项目目录：

```bash
sudo bash install.sh notes.your-domain.com --email you@your-domain.com
```

不传 `--repo` 时，优先使用它旁边的 `site/`，适合本地上传或 ZIP 部署；
如果只下载了脚本，会自动从 `laoluonb/reality-site` 下载网站文件。

### 从 GitHub 无交互安装

本项目仓库为 `laoluonb/reality-site`，默认分支为 `main`。
下面只需替换域名和邮箱。命令分步检查下载是否成功，再执行。
如果使用你自己 fork 的仓库，再把两处 `laoluonb/reality-site` 都换成你的仓库名称。

```bash
curl -fL --retry 3 --retry-all-errors --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/laoluonb/reality-site/main/install.sh \
  -o /tmp/reality-site-install.sh \
  && sudo bash /tmp/reality-site-install.sh notes.your-domain.com \
  --email you@your-domain.com --repo laoluonb/reality-site
```

可用 `--ref` 指定某个提交或标签。若不用 `main`，安装脚本的下载 URL 和 `--ref` 要保持一致。
私有仓库不支持这种免登录拉取方式。
安装时指定的 `--repo` 和 `--ref` 会写入本项目管理的 Nginx 配置注释，供菜单更新网页时继续使用。
完整项目的本地安装默认将后续更新来源设为 `laoluonb/reality-site`，需要自定义来源时请指定 `--repo`。

其他无交互操作：

```bash
sudo bash install.sh --status
sudo bash install.sh --update-site
sudo bash install.sh --show-reality
sudo bash install.sh --check
sudo bash install.sh --renew-test
sudo bash install.sh --randomize-site
```

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
- 在 GitHub 更新网站后，选择菜单 2 即可拉取网页更新，不重新执行证书申请。
- 一个服务器上的本脚本只管理一个域名。已有其他 Nginx 站点不会被删除；检测到明显域名或端口冲突时停止。
- 安装失败会恢复之前受本脚本管理的 Nginx 配置。已安装的软件、网站文件和已申请的证书会保留。
- 没有自动修改系统防火墙或云安全组。

网站无外部字体、脚本或运行时依赖。图片保存在仓库内。
山间手记的内容和样式在 `site/` 中，其他三套在 `templates/architecture/`、
`templates/garden/`、`templates/coast/` 中，每套均包含 `index.html`、`styles.css` 和 `assets/landscape.jpg`。
网页更新会覆盖当前模板的这三个文件，请先在仓库修改内容再执行更新。

## 图片与许可

网站照片来自 Unsplash：

- 山间手记：`https://images.unsplash.com/photo-1472396961693-142e6e269027`
- 构筑笔记：`https://images.unsplash.com/photo-1487958449943-2429e8be8625`
- 叶间日常：`https://images.unsplash.com/photo-1416879595882-3373a0480b5b`
- 海岸来信：`https://images.unsplash.com/photo-1500375592092-40eb2168fd21`

遵循 Unsplash License：https://unsplash.com/license 。
仓库中的 MIT 许可覆盖代码与原创文字，不替代照片的原始许可。

## 参考

- REALITY 官方：https://github.com/XTLS/REALITY
- Xray 配置：https://xtls.github.io/config/transport.html
- Certbot：https://eff-certbot.readthedocs.io/en/stable/using.html

## 本地检查

```bash
bash -n install.sh
shellcheck install.sh tests/menu-and-templates.sh
bash tests/menu-and-templates.sh
```

测试在临时目录中模拟网站更新，不安装软件、不申请证书、不更改系统配置。
