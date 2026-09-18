// 江苏海洋大学校园网自动登录（iPhone / Scriptable）
// 首次运行填写账号和密码；密码仅存进本机 iPhone 钥匙串。
// 需要连接学校校园 Wi-Fi 后运行。本脚本固定使用中国联通 @unicom。

const PORTAL_ROOT = "http://210.28.39.250/";
const API_ROOT = "http://210.28.39.250:803/eportal/portal/";
const KEY_PREFIX = "jou-campus-autologin-v1-";

function key(name) { return KEY_PREFIX + name; }

function xorHex(value, ip) {
  let n = 0;
  for (const ch of ip) n ^= ch.charCodeAt(0);
  let output = "";
  for (const ch of String(value)) {
    output += (ch.charCodeAt(0) ^ n).toString(16).padStart(2, "0");
  }
  return output;
}

function query(values) {
  return Object.entries(values)
    .map(([name, value]) => encodeURIComponent(name) + "=" + encodeURIComponent(String(value)))
    .join("&");
}

function jsonp(text) {
  const match = String(text).match(/^[\s\S]*?\(\s*(\{[\s\S]*\})\s*\)\s*;?\s*$/);
  if (!match) throw new Error("学校认证服务器返回内容无法识别。");
  return JSON.parse(match[1]);
}

async function getText(url) {
  if (!/^http:\/\/210\.28\.39\.250(?::(?:80|803))?\//.test(url)) {
    throw new Error("认证地址不符合学校地址，已停止。");
  }
  const request = new Request(url);
  request.timeoutInterval = 12;
  request.allowInsecureRequest = true;
  request.headers = { "User-Agent": "JOU-iPhone-AutoLogin/1.0" };
  const text = await request.loadString();
  if (request.response.statusCode !== 200) throw new Error("学校认证服务器暂时不可用。");
  return text;
}

async function portal(action, data, ip, encrypt = true) {
  if (!["page/loadConfig", "online_list", "login"].includes(action)) {
    throw new Error("不支持的认证操作。");
  }
  const values = { ...data, callback: "dr1001", jsVersion: "4.X" };
  if (encrypt) {
    for (const name of Object.keys(values)) values[name] = xorHex(values[name], ip);
    values.encrypt = "1";
  }
  return jsonp(await getText(API_ROOT + action + "?" + query(values)));
}

async function getContext() {
  const html = await getText(PORTAL_ROOT);
  const ip = (html.match(/v46ip='([^']+)'/) || [])[1];
  if (!ip) throw new Error("没有识别到校园网地址。请先连接学校 Wi-Fi 后再运行。");
  const mac = ((html.match(/ss4="([^"]+)"/) || [])[1] || "000000000000").toUpperCase();
  const vlan = (html.match(/vlanid="([^"]*)"/) || [])[1] || "";
  const encodedIp = Data.fromString(ip).toBase64String();
  const config = await portal("page/loadConfig", {
    program_index: "", wlan_vlan_id: vlan, wlan_user_ip: encodedIp, wlan_user_ipv6: "",
    wlan_user_ssid: "", wlan_user_areaid: "", wlan_ac_ip: "", wlan_ap_mac: "000000000000", gw_id: "000000000000"
  }, ip, false);
  if (String(config.code) !== "1" || String(config.data?.login_method) !== "1" || String(config.data?.enable_r3) !== "0") {
    throw new Error("学校认证方式发生变化，需要更新脚本。");
  }
  return { ip, mac, vlan, settings: config.data };
}

async function isOnline(context) {
  const reply = await portal("online_list", {
    user_account: "", user_password: "", wlan_user_mac: context.mac,
    wlan_user_ip: Data.fromString(context.ip).toBase64String(), wlan_user_ipv6: ""
  }, context.ip);
  if (!["0", "1"].includes(String(reply.result))) throw new Error("无法判断当前认证状态。");
  return String(reply.result) === "1";
}

async function askForAccount() {
  const alert = new Alert();
  alert.title = "江苏海洋大学校园网";
  alert.message = "首次设置：运营商已固定为中国联通。账号密码只保存在这台 iPhone 的钥匙串中。";
  alert.addTextField("校园网账号");
  alert.addSecureTextField("校园网密码");
  alert.addAction("保存并登录");
  alert.addCancelAction("取消");
  const result = await alert.presentAlert();
  if (result === -1) return null;
  const account = alert.textFieldValue(0).trim();
  const password = alert.textFieldValue(1);
  if (!account || !password) throw new Error("账号和密码都需要填写。");
  Keychain.set(key("account"), account);
  Keychain.set(key("password"), password);
  return { account, password };
}

async function notify(title, body) {
  if (config.runsInApp) {
    const alert = new Alert();
    alert.title = title;
    alert.message = body;
    alert.addAction("好");
    await alert.presentAlert();
  } else {
    const notice = new Notification();
    notice.title = title;
    notice.body = body;
    await notice.schedule();
  }
}

async function main() {
  // 从快捷指令传入 reset，可重新填写账号密码：运行 Scriptable 时传参数 reset。
  if (args.shortcutParameter === "reset") {
    Keychain.remove(key("account"));
    Keychain.remove(key("password"));
  }
  let credentials;
  if (Keychain.contains(key("account")) && Keychain.contains(key("password"))) {
    credentials = { account: Keychain.get(key("account")), password: Keychain.get(key("password")) };
  } else {
    credentials = await askForAccount();
    if (!credentials) return;
  }

  const context = await getContext();
  if (await isOnline(context)) {
    await notify("校园网已在线", "无需重复登录。");
    return;
  }

  let account = credentials.account.replace(/^,[01],/, "").replace(/@(unicom|cmcc|telecom)$/, "") + "@unicom";
  let password = credentials.password;
  const useBase64 = String(context.settings.no_filter_accandpwd) === "1";
  if (useBase64) {
    account = Data.fromString(account).toBase64String();
    password = Data.fromString(password).toBase64String();
  }
  const reply = await portal("login", {
    login_method: "1", is_base64encode: useBase64 ? "1" : "0", user_account: account, user_password: password,
    wlan_user_ip: context.ip, wlan_user_ipv6: "", wlan_user_mac: context.mac, wlan_vlan_id: context.vlan,
    wlan_ac_ip: "", wlan_ac_name: "", authex_enable: "", terminal_type: "1", lang: "zh-cn",
    user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS like Mac OS X)", enable_r3: "0", mac_type: "0",
    rcn: context.settings.rcn || "", operate: "portal_login", business_type: "1"
  }, context.ip);
  if (!["1", "ok"].includes(String(reply.result))) {
    throw new Error(reply.msg || "认证未成功，请检查账号或密码。");
  }
  await notify("校园网登录成功", "已按中国联通完成认证。");
}

try {
  await main();
} catch (error) {
  await notify("校园网自动登录失败", String(error.message || error));
}
Script.complete();
