'use strict';
'require ui';
'require form';
'require rpc';
'require uci';
'require view';

const callStatus = rpc.declare({ object: 'luci.cfipopt', method: 'get_status', expect: {} });
const callStart = rpc.declare({ object: 'luci.cfipopt', method: 'start', expect: {} });
const callStop = rpc.declare({ object: 'luci.cfipopt', method: 'stop', expect: {} });
const callProxy = rpc.declare({ object: 'luci.cfipopt', method: 'proxy', expect: {} });
const callCheckUpdate = rpc.declare({ object: 'luci.cfipopt', method: 'check_update', expect: {} });
const callUpdate = rpc.declare({ object: 'luci.cfipopt', method: 'update', expect: {} });

return view.extend({
	load: function () {
		// 后台触发一次更新检查(服务端有 1h 缓存), 不阻塞页面渲染
		callCheckUpdate().catch(function () {});
		return callStatus().catch(function () {
			return { state: 'idle', total: 0, done: 0, log: '', result: '', proxy: null };
		});
	},

	render: function (initial) {
		let self = this;
		this.timer = null;

		let m = new form.Map('cfipopt', _('CF IP 优选测速'),
			_('参照 cmliu/edgetunnel 的优选逻辑: 从 Cloudflare CIDR 段随机生成候选 IP / 拉取优选 API, 绕过代理直连测速, 输出可直接用于 edgetunnel 实例节点列表的结果 (每行 IP:端口#备注).'));
		this.map = m;

		/* ---- 状态卡片 ---- */
		this.proxyLine = E('span', {}, '');
		this.stateLine = E('span', {}, '');
		this.versionLine = E('span', {}, '');
		this.updateProgressLine = E('span', { style: 'color:#e80;margin-left:8px' }, '');
		this.progressInner = E('div', {
			class: 'cbi-progressbar-inner',
			style: 'width:0%'
		}, '');
		this.progressWrap = E('div', {
			class: 'cbi-progressbar',
			style: 'width:100%'
		}, this.progressInner);
		this.btnStart = E('button', {
			class: 'cbi-button cbi-button-action',
			click: function () { self.onStart(); }
		}, _('开始测速'));
		this.btnStop = E('button', {
			class: 'cbi-button cbi-button-negative',
			click: function () { self.onStop(); }
		}, _('停止'));
		this.btnStop.disabled = true;
		this.btnCheck = E('button', {
			class: 'cbi-button',
			click: function () { self.onCheckUpdate(); }
		}, _('检查更新'));
		this.btnUpdate = E('button', {
			class: 'cbi-button cbi-button-apply',
			click: function () { self.onUpdate(); }
		}, _('立即更新'));
		this.btnUpdate.disabled = true;
		this.updating = false;

		let statusCard = E('div', { class: 'cbi-section' }, [
			E('h3', _('测速状态')),
			E('div', { class: 'cbi-section-descr', style: 'margin-bottom:10px' }, [
				this.proxyLine,
				E('br'),
				this.stateLine,
				E('br'),
				this.versionLine,
				this.updateProgressLine
			]),
			this.progressWrap,
			E('div', { class: 'right', style: 'margin-top:10px' }, [
				this.btnStart,
				this.btnStop,
				this.btnCheck,
				this.btnUpdate
			])
		]);

		/* ---- 配置 ---- */
		let s = m.section(form.NamedSection, 'config', 'cfipopt', _('测速配置'));

		let o = s.option(form.Value, 'count', _('随机候选 IP 数量'), _('从 CIDR 段内随机生成并参与测速的 IP 数量'));
		o.datatype = 'uinteger';
		o.default = '40';

		o = s.option(form.Value, 'top', _('输出最优节点数量'));
		o.datatype = 'uinteger';
		o.default = '10';

		o = s.option(form.Value, 'port', _('固定测速端口'), _('留空则从下方端口池中随机选择 (edgetunnel 风格)'));
		o.datatype = 'port';
		o.optional = true;

		o = s.option(form.Value, 'ports', _('端口池'), _('空格分隔, 用于随机端口模式'));
		o.default = '443 2053 2083 2087 2096 8443';

		o = s.option(form.ListValue, 'test_mode', _('候选来源模式'));
		o.value('both', _('优选 API + 随机生成'));
		o.value('random', _('仅随机生成'));
		o.value('api', _('仅优选 API'));
		o.value('latency', _('仅随机生成 (只测延迟)'));
		o.default = 'both';

		o = s.option(form.ListValue, 'cidr_source', _('CIDR 来源'));
		o.value('official', _('Cloudflare 官方 (cloudflare.com/ips-v4)'));
		o.value('list', _('自定义列表'));
		o.default = 'official';

		o = s.option(form.TextValue, 'cidr_custom', _('自定义 CIDR 列表'), _('每行一个, 例如 104.16.0.0/13。cmliu/CF-CIDR 上游已失效, 可粘贴备份的电信/联通/移动分段'));
		o.rows = 4;
		o.optional = true;

		o = s.option(form.TextValue, 'api_urls', _('优选 API 地址'), _('每行一个, 返回内容为每行一个 IP:端口#备注 (与 edgetunnel 的优选 API 一致)。URL 后可用 #备注 为结果统一命名'));
		o.rows = 3;
		o.optional = true;

		o = s.option(form.TextValue, 'custom_ips', _('自定义 IP 列表'), _('每行一个 IP:端口#备注, 直接参与测速'));
		o.rows = 3;
		o.optional = true;

		o = s.option(form.Value, 'remark_prefix', _('结果备注前缀'), _('随机候选节点的备注, 如 CF优选1'));
		o.default = 'CF优选';

		o = s.option(form.Value, 'max_latency', _('最大延迟 (ms)'), _('超过该延迟的节点将被过滤'));
		o.datatype = 'uinteger';
		o.default = '500';

		o = s.option(form.Value, 'min_speed', _('最低下载速度 (Mbps)'), _('低于该速度的节点将被过滤, 0 表示不限制'));
		o.datatype = 'uinteger';
		o.default = '0';

		o = s.option(form.Value, 'test_bytes', _('测速下载大小 (字节)'), _('每个节点下载的测试流量, 0 = 仅测延迟'));
		o.datatype = 'uinteger';
		o.default = '5242880';

		o = s.option(form.Value, 'parallel', _('并发测速数'));
		o.datatype = 'uinteger';
		o.default = '4';

		o = s.option(form.ListValue, 'bypass_mode', _('代理绕过方式'), _('auto: 检测到 OpenClash 时以 nobody (gid 65534) 身份直连测速; 该豁免由 OpenClash 自身 mangle 规则提供'));
		o.value('auto', _('自动检测'));
		o.value('nobody', _('强制 gid 65534 绕过'));
		o.value('none', _('不绕过'));
		o.default = 'auto';

		o = s.option(form.Value, 'connect_timeout', _('连接超时 (秒)'));
		o.datatype = 'uinteger';
		o.default = '3';

		o = s.option(form.Value, 'max_time', _('单节点测试总超时 (秒)'));
		o.datatype = 'uinteger';
		o.default = '8';

		o = s.option(form.Value, 'api_count', _('单个优选 API 最多取节点数'));
		o.datatype = 'uinteger';
		o.default = '30';

		o = s.option(form.Value, 'max_candidates', _('候选节点总数上限'));
		o.datatype = 'uinteger';
		o.default = '200';

		/* ---- 日志 + 结果 ---- */
		this.logBox = E('pre', {
			style: 'height:240px;overflow:auto;background:#111;color:#4f8;font:12px/1.55 monospace;padding:10px;border-radius:4px;white-space:pre-wrap;word-break:break-all'
		}, '');

		this.resultBox = E('textarea', {
			rows: 12,
			style: 'width:100%;font-family:monospace',
			readonly: 'readonly',
			placeholder: _('测速完成后, 此处为可直接粘贴到 edgetunnel 实例节点列表的结果 (每行 IP:端口#备注)')
		}, '');

		let resultBtns = E('div', { class: 'right', style: 'margin-top:8px' }, [
			E('button', {
				class: 'cbi-button cbi-button-action',
				click: function () { self.copyResult(); }
			}, _('复制结果')),
			E('button', {
				class: 'cbi-button',
				click: function () { self.downloadResult(); }
			}, _('下载文件'))
		]);

		let logSection = E('div', { class: 'cbi-section' }, [
			E('h3', _('实时日志')),
			this.logBox
		]);
		let resultSection = E('div', { class: 'cbi-section' }, [
			E('h3', _('优选结果 (edgetunnel 节点列表格式)')),
			this.resultBox,
			resultBtns
		]);

		this.renderStatus(initial);

		this.timer = setInterval(function () {
			self.refresh();
		}, 2000);

		// m.render() 返回 Promise, 必须等它解析出表单 DOM 后再组装页面
		return m.render().then(function (mapEl) {
			return E('div', {}, [ statusCard, mapEl, logSection, resultSection ]);
		});
	},

	refresh: function () {
		let self = this;
		callStatus().then(function (st) {
			self.renderStatus(st);
		}).catch(function () {});
	},

	renderStatus: function (st) {
		if (st.proxy) {
			let color = st.proxy.active ? 'orange' : 'green';
			this.proxyLine.innerHTML = '';
			this.proxyLine.appendChild(E('strong', { style: 'color:' + color }, _('代理状态: ') + (st.proxy.active ? st.proxy.name + ' (' + (st.proxy.mode || '') + ')' : _('未检测到代理'))));
			this.proxyLine.appendChild(E('span', { style: 'color:#666;margin-left:8px' }, st.proxy.detail || ''));
		}

		let running = (st.state === 'running');
		let pct = (st.total > 0) ? Math.round(st.done / st.total * 100) : 0;
		this.progressInner.style.width = pct + '%';
		this.progressInner.textContent = (st.total > 0) ? (st.done + ' / ' + st.total) : '';

		let stateTxt = {
			'idle': _('空闲'),
			'running': _('测速中'),
			'done': _('已完成'),
			'error': _('出错'),
			'stopped': _('已停止')
		}[st.state] || st.state;
		this.stateLine.innerHTML = '';
		this.stateLine.appendChild(E('strong', {}, _('状态: ') + stateTxt + '   ' + (st.total > 0 ? pct + '%' : '')));

		if (st.update)
			this.renderUpdate(st.update);

		if (st.update_progress) {
			let pmap = {
				'downloading': _('正在下载新版...'),
				'installing': _('正在安装...'),
				'done': _('更新完成, 请刷新页面'),
				'failed': _('更新失败, 见日志')
			};
			this.updateProgressLine.textContent = pmap[st.update_progress] || '';
			this.updateProgressLine.style.color = (st.update_progress === 'failed') ? '#c00' : '#e80';
			if (st.update_progress === 'done' || st.update_progress === 'failed') {
				this.updating = false;
				this.btnCheck.disabled = false;
			}
		}

		this.btnStart.disabled = running;
		this.btnStop.disabled = !running;
		this.btnCheck.disabled = this.updating;
		this.btnUpdate.disabled = this.updating || !this.lastUpdateAvailable;

		if (st.log) {
			this.logBox.textContent = st.log;
			this.logBox.scrollTop = this.logBox.scrollHeight;
		}
		if (st.result) {
			this.resultBox.value = st.result;
		}
	},

	renderUpdate: function (up) {
		this.lastUpdateAvailable = !!up.update_available;
		let inst = up.installed ? 'v' + String(up.installed) : '?';
		let lat = up.latest ? 'v' + String(up.latest) : '—';
		this.versionLine.innerHTML = '';
		this.versionLine.appendChild(E('span', {}, _('当前版本: ') + inst + '   ' + _('最新版本: ') + lat + '  '));
		if (up.update_available) {
			this.versionLine.appendChild(E('strong', { style: 'color:orange' }, _('(有可用更新)')));
		}
		else if (up.latest) {
			this.versionLine.appendChild(E('span', { style: 'color:green' }, _('(已是最新)')));
		}
		else {
			this.versionLine.appendChild(E('span', { style: 'color:#999' }, _('(检查失败或暂无 Release)')));
		}
		this.btnUpdate.disabled = this.updating || !this.lastUpdateAvailable;
	},

	onStart: function () {
		let self = this;
		let savePromise = Promise.resolve();
		if (this.map)
			savePromise = this.map.save();
		savePromise.then(function () {
			return callStart();
		}).then(function () {
			self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, _('启动失败: ') + String(e)));
			console.error('cfipopt start failed:', e);
		});
	},

	onStop: function () {
		let self = this;
		callStop().then(function () {
			self.refresh();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, _('停止失败: ') + String(e)));
		});
	},

	onCheckUpdate: function () {
		let self = this;
		this.updateProgressLine.textContent = _('正在检查更新...');
		callCheckUpdate().then(function (up) {
			self.renderUpdate(up);
			self.updateProgressLine.textContent = '';
			self.refresh();
		}).catch(function (e) {
			self.updateProgressLine.textContent = _('检查失败: ') + String(e);
		});
	},

	onUpdate: function () {
		let self = this;
		if (!confirm(_('确定要更新到最新版本吗? 更新完成后请刷新页面。')))
			return;
		this.updating = true;
		this.btnUpdate.disabled = true;
		this.btnCheck.disabled = true;
		this.updateProgressLine.textContent = _('更新中... (下载/安装约需 1-2 分钟)');
		callUpdate().then(function () {
			// 后台执行, 轮询 get_status 中的 update_progress
			self.refresh();
		}).catch(function (e) {
			self.updating = false;
			self.updateProgressLine.textContent = _('更新失败: ') + String(e);
		});
	},

	copyResult: function () {
		let ta = this.resultBox;
		ta.focus();
		ta.select();
		ta.setSelectionRange(0, 999999);
		try {
			document.execCommand('copy');
		}
		catch (e) {
			if (navigator.clipboard && navigator.clipboard.writeText)
				navigator.clipboard.writeText(ta.value).catch(function () {});
		}
	},

	downloadResult: function () {
		let blob = new Blob([ this.resultBox.value || '' ], { type: 'text/plain' });
		let a = document.createElement('a');
		a.href = URL.createObjectURL(blob);
		a.download = 'edgetunnel-ips.txt';
		document.body.appendChild(a);
		a.click();
		document.body.removeChild(a);
		URL.revokeObjectURL(a.href);
	}
});
