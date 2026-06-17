'use strict';
'require view';
'require fs';
'require ui';
'require form';

/**
 * Xray Status Dashboard — LuCI app for OpenWrt 25.12+
 * Reads /etc/xray/settings.json and /etc/xray/config.json
 */

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function () {
		return Promise.all([
			fs.read('/etc/xray/settings.json'),
			fs.read('/etc/xray/config.json')
		]);
	},

	render: function (data) {
		var settings = {}, config = {};

		try { settings = JSON.parse(data[0] || '{}'); } catch(e) {}
		try { config = JSON.parse(data[1] || '{}'); } catch(e) {}

		var sub = settings.subscription || {};
		var routing = settings.routing || {};
		var geo = settings.geo || {};
		var outbounds = config.outbounds || [];
		var proxies = outbounds.filter(function(ob) {
			return ob.protocol !== 'freedom' && ob.protocol !== 'blackhole' && ob.protocol !== 'dns';
		});

		// ─── Статус-индикаторы ───
		var proxyCount = proxies.length;
		var hasConfig = !!config.outbounds;
		var statusClass = proxyCount > 0 ? 'cbi-section-create' : 'cbi-section-warning';
		var statusText = proxyCount > 0
			? _('Active: %d proxy servers').format(proxyCount)
			: _('No proxy servers — DIRECT mode or subscription expired');

		// ─── Секция: Система ───
		var sysRows = [
			E('div', { 'class': 'tr' }, [
				E('span', { 'class': 'td left', 'style': 'width:35%' }, _('Device')),
				E('span', { 'class': 'td left' }, settings.device_model || '—')
			]),
			E('div', { 'class': 'tr' }, [
				E('span', { 'class': 'td left' }, _('OS')),
				E('span', { 'class': 'td left' }, (settings.device_os || '') + ' ' + (settings.ver_os || ''))
			]),
			E('div', { 'class': 'tr' }, [
				E('span', { 'class': 'td left' }, _('HWID')),
				E('span', { 'class': 'td left' }, (settings.hwid || '').substring(0, 24) || '—')
			])
		];

		// ─── Секция: Подписка ───
		var subUrl = sub.url || '';
		var subRows = [
			E('div', { 'class': 'tr' }, [
				E('span', { 'class': 'td left', 'style': 'width:35%' }, _('URL')),
				E('span', { 'class': 'td left' }, subUrl.length > 40 ? subUrl.substring(0, 40) + '…' : (subUrl || '—'))
			]),
			E('div', { 'class': 'tr' }, [
				E('span', { 'class': 'td left' }, _('User-Agent')),
				E('span', { 'class': 'td left' }, sub.user_agent || '—')
			]),
			E('div', { 'class': 'tr' }, [
				E('span', { 'class': 'td left' }, _('Proxies')),
				E('span', { 'class': 'td left' }, proxyCount > 0
					? E('strong', { 'style': 'color:#4caf50' }, proxyCount)
					: E('strong', { 'style': 'color:#f44336' }, _('none')))
			])
		];

		if (sub.remarks_filter) {
			subRows.push(E('div', { 'class': 'tr' }, [
				E('span', { 'class': 'td left' }, _('Filter')),
				E('span', { 'class': 'td left' }, sub.remarks_filter)
			]));
		}

		// ─── Секция: Прокси-серверы ───
		var proxyRows = [];
		if (proxies.length > 0) {
			proxies.forEach(function(ob, i) {
				var vnext = (ob.settings && ob.settings.vnext && ob.settings.vnext[0]) || {};
				var addr = vnext.address || '?';
				var port = vnext.port || '?';
				var stream = ob.streamSettings || {};
				var net = stream.network || 'tcp';
				var sec = stream.security || 'none';
				var transport = sec + '/' + net;

				if (net === 'ws') {
					var path = (stream.wsSettings && stream.wsSettings.path) || '/';
					transport += ' path=' + path;
				} else if (net === 'grpc') {
					var svc = (stream.grpcSettings && stream.grpcSettings.serviceName) || '';
					if (svc) transport += ' svc=' + svc;
				}

				proxyRows.push(E('div', { 'class': 'tr' }, [
					E('span', { 'class': 'td left', 'style': 'font-family:monospace;font-size:90%' },
						(i + 1) + '. ' + (ob.tag || 'proxy-' + i)),
					E('span', { 'class': 'td left', 'style': 'font-family:monospace;font-size:85%' },
						(ob.protocol || '?').toUpperCase() + ' → ' + addr + ':' + port),
					E('span', { 'class': 'td left', 'style': 'font-size:85%' }, '[' + transport + ']')
				]));
			});
		} else {
			proxyRows.push(E('div', { 'class': 'tr' }, [
				E('span', { 'class': 'td left', 'style': 'color:#999' }, _('No active proxy servers'))
			]));
		}

		// ─── Секция: Роутинг ───
		var routeRows = [];
		var routeInfo = [
			{ label: _('DNS Strategy'), value: routing.domainStrategy || '—' },
			{ label: _('Direct IPs'), value: (routing.direct_ips || []).join(', ') },
			{ label: _('Direct Domains'), value: (routing.direct_domains || []).join(', ') },
			{ label: _('Proxy Domains'), value: (routing.proxy_domains || []).join(', ') },
			{ label: _('Blocked'), value: (routing.block_domains || []).join(', ') },
			{ label: _('DoH Servers'), value: (routing.doh_domains || []).length + ' servers' }
		];

		routeInfo.forEach(function(item) {
			if (item.value) {
				routeRows.push(E('div', { 'class': 'tr' }, [
					E('span', { 'class': 'td left', 'style': 'width:30%' }, item.label),
					E('span', { 'class': 'td left', 'style': 'font-size:85%' }, item.value)
				]));
			}
		});

		// ─── Сборка страницы ───
		return E('div', { 'class': 'cbi-map' }, [
			// Заголовок
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Xray TProxy Status')),
				E('div', { 'class': statusClass, 'style': 'margin-bottom:15px' },
					statusText)
			]),

			// Система
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('System')),
				E('div', { 'class': 'table cbi-section-table', 'style': 'width:100%' }, [
					E('div', { 'class': 'tr cbi-section-table-titles' }, [
						E('span', { 'class': 'th' }, _('Parameter')),
						E('span', { 'class': 'th' }, _('Value'))
					])
				].concat(sysRows))
			]),

			// Подписка
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Subscription')),
				E('div', { 'class': 'table cbi-section-table', 'style': 'width:100%' }, [
					E('div', { 'class': 'tr cbi-section-table-titles' }, [
						E('span', { 'class': 'th' }, _('Parameter')),
						E('span', { 'class': 'th' }, _('Value'))
					])
				].concat(subRows))
			]),

			// Прокси
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Proxy Servers')),
				E('div', { 'class': 'table cbi-section-table', 'style': 'width:100%' }, [
					E('div', { 'class': 'tr cbi-section-table-titles' }, [
						E('span', { 'class': 'th', 'style': 'width:30%' }, _('Name')),
						E('span', { 'class': 'th', 'style': 'width:40%' }, _('Address')),
						E('span', { 'class': 'th' }, _('Transport'))
					])
				].concat(proxyRows))
			]),

			// Роутинг
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Routing Rules')),
				E('div', { 'class': 'table cbi-section-table', 'style': 'width:100%' }, [
					E('div', { 'class': 'tr cbi-section-table-titles' }, [
						E('span', { 'class': 'th' }, _('Rule')),
						E('span', { 'class': 'th' }, _('Value'))
					])
				].concat(routeRows))
			]),

			// Geo
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Geo Data')),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, 'GeoIP'),
					E('div', { 'class': 'cbi-value-field' }, (geo.geoip_url || '—').substring(0, 60) + '…')
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, 'GeoSite'),
					E('div', { 'class': 'cbi-value-field' }, (geo.geosite_url || '—').substring(0, 60) + '…')
				])
			]),

			// Footer
			E('div', { 'class': 'cbi-section', 'style': 'margin-top:20px;color:#888;font-size:85%' }, [
				E('p', {}, _('XPowerSpirit Xray TProxy for OpenWrt')),
				E('p', {}, _('CLI: xray-status --full  |  Package: luci-app-xray'))
			])
		]);
	}
});
