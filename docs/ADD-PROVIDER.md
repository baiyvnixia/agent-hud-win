# 新增一个 AI 供应商（不用改代码）

浮窗的数据全来自 `providers.json` 里的一张声明式表。绝大多数供应商**只要加一段 JSON**
就能接进来——包括「其他同志不止三个 agent」的情况，加多少个都行，浮窗会自动多出一行。

---

## 一、先判断：你的接口属于哪种？

| 你的余额接口长什么样 | 用哪种方式 |
|---|---|
| GET 一个 URL，返回 JSON 里某个字段是余额（或数组里每项是余额） | **纯配置**（本文第二节） |
| 返回结构很绕：要按 token 算、要两次请求、要做减法 | 写一个内置适配器（第三节） |

---

## 二、纯配置接入（推荐）

在 `providers.json` 的数组里加一项：

```json
{
  "id": "my-llm",
  "label": "我的模型",
  "color": "#22C55E",
  "icon": "icons/example-generic.png",
  "auth": {
    "env": ["MY_LLM_API_KEY"],
    "header": "Authorization",
    "scheme": "Bearer "
  },
  "request": {
    "url": "https://my-llm.example.com/api/balance",
    "headers": { "X-Extra": "可选额外头" }
  },
  "response": {
    "listPath": "data.balances",
    "amountPath": "available",
    "capacityPath": "total",
    "unitPath": "unit",
    "labelPath": "name",
    "expiresPath": "expire_at"
  },
  "reference": 10
}
```

字段说明：

| 字段 | 必填 | 作用 |
|---|---|---|
| `id` | ✅ | 唯一标识。`config.json` 的 `providerIcons` / `providerColors` 用这个键 |
| `label` | ✅ | 浮窗悬停/明细框里显示的名字 |
| `color` | | 圆环颜色（十六进制） |
| `icon` | | 图标路径，相对仓库根。**没有就删掉这行**，会自动用「品牌色首字母」占位 |
| `auth.env` | | 去哪几个环境变量里找 key（按顺序取第一个存在的）。**没有就删掉 `auth` 整段** |
| `auth.header` | | key 放在哪个请求头，默认 `Authorization` |
| `auth.scheme` | | key 前缀，通常是 `"Bearer "`（**末尾有个空格**） |
| `request.url` | ✅ | 请求地址 |
| `request.headers` | | 额外请求头 |
| `response.listPath` | | 余额所在的点路径。返回是数组就不填 |
| `response.amountPath` | | 数组每项里「剩余/可用」的字段名 |
| `response.capacityPath` | | 「总量」字段名。有总量圆环才能画百分比；没有就只显示数值 |
| `response.unitPath` | | 单位字段名 |
| `response.labelPath` | | 每项的名字字段 |
| `response.expiresPath` | | 到期时间字段 |
| `reference` | | 没有总量时，圆环按 `余额 / reference` 画。比如你一般充 20 块就写 `20` |

### 点路径怎么写

`data.balances` 表示 `body.data.balances`；数组下标也能写，如 `data.0.amount`。

### 举几个例子

**返回是数组本身：**

```json
"request": { "url": "https://api.example.com/credits" },
"response": { "amountPath": "remain", "capacityPath": "total" }
```

**返回是单个对象：**

```json
"response": { "amountPath": "data.balance" }
```

**key 没有前缀：**

```json
"auth": { "env": ["MY_KEY"], "header": "X-Api-Key", "scheme": "" }
```

---

## 三、写内置适配器（绕的才需要）

打开 `snapshot.mjs`，在 `ADAPTERS` 对象里加一个同名函数，然后 provider 里写 `"adapter": "你的名字"`。

```js
const ADAPTERS = {
  // ...已有的 deepseek / moonshot / zhipu / openrouter

  myllm: async (ctx, def) => {
    // ctx.get(url) 已经帮你带好了鉴权头，返回解析后的 JSON
    const body = await ctx.get(def.request.url);
    const remain = Number(body.data.balance);
    const total  = Number(body.data.quota);
    return [{
      label: '主额度',
      amount: remain,
      unit: 'tokens',
      capacity: total,
      ratio: total > 0 ? remain / total : null,
      kind: 'quota',
      text: `${remain} / ${total}`,
      expiresAt: body.data.expire_at || null,
    }];
  },
};
```

适配器返回一个数组，每项字段：

| 字段 | 说明 |
|---|---|
| `label` | 这一项叫什么（明细框里显示） |
| `amount` | 剩余数值 |
| `capacity` | 总量（没有就 `null`） |
| `ratio` | 剩余比例 0~1（给了就优先用它画圆环） |
| `unit` | 单位 |
| `kind` | `balance`（现金）或 `quota`（额度/资源包） |
| `text` | 明细框里那行的文字 |
| `expiresAt` | 到期时间（ISO 字符串） |

> 一个 provider 返回多个 item 时，浮窗的圆环取**最紧的那一项**（剩余比例最小的），
> 这样你不会因为某个大方用不完就忽略了快到期的那个。

---

## 四、把 key 存哪

三种都行，优先级从高到低：

```powershell
# 1. 环境变量（当前会话）
$env:MY_LLM_API_KEY = "sk-xxx"
# 永久（新开终端也有效）
[Environment]::SetEnvironmentVariable('MY_LLM_API_KEY','sk-xxx','User')
```

```json
// 2. providers.local.json（已在 .gitignore 里，不会被提交）
{ "keys": { "MY_LLM_API_KEY": "sk-xxx" } }
```

3. 如果你装了 DSH，它会自动读 `~/.dsh/.credentials.yaml` 的 refs 段。

---

## 五、验证

```powershell
# 看哪些 provider 配好了 key
node snapshot.mjs --check

# 真拉一次，只看结构
node snapshot.mjs --pretty
```

`--check` 里显示 `-- 未配置` 的 provider 会被静默跳过（不会在浮窗上显示成红色错误）。
如果某个 provider 显示了但报错，浮窗上它的圆环会变红，鼠标悬停能看到错误原因。

---

## 六、图标

不放图标也能用（自动用品牌色字母）。想换真 logo：

1. 把 png 丢进 `icons/`（建议 256×256，透明背景）
2. 在 `config.json` 的 `providerIcons` 里加 `"你的id": "icons/你的图.png"`

⚠️ 厂商 logo 属于各自的商标，仓库默认只带生成的占位图，请自行确认使用授权。
