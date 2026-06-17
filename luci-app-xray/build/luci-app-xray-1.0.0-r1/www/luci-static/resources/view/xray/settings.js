'use strict';
'require view';
'require fs';
'require ui';
'require form';

/**
 * Xray Settings Form — LuCI app
 * Edit subscription settings stored in /etc/xray/settings.json
 */

return view.extend({
	render: function () {
		var settings = {};

		// ─── Загружаем текущие настройки ───
		// Будем загружать в load()
		// Пока используем синхронный подход через ui

		var m, s, o;

		m = new form.Map('xray-settings', _('Xray Subscription Settings'),
			_('Configure subscription URL, User-Agent, and filtering options.'));

		// ─── Секция: Подписка ───
		s = m.section(form.TypedSection, 'subscription', _('Subscription'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'url', _('Subscription URL'),
			_('Full URL to the subscription endpoint (VLESS or JSON format).'));
		o.placeholder = 'https://example.com/subscribe';
		o.datatype = 'string';

		o = s.option(form.Value, 'user_agent', _('User-Agent'),
			_('User-Agent header sent with the subscription request. Use XPower/1.0 for JSON format, or leave default for Base64 VLESS.'));
		o.placeholder = 'XPower/1.0';
		o.datatype = 'string';
		o.default = 'XPower/1.0';

		o = s.option(form.Value, 'remarks_filter', _('Remarks Filter'),
			_('Optional: filter subscription profiles by remarks field (JSON format only).'));
		o.placeholder = '';
		o.datatype = 'string';
		o.optional = true;

		o = s.option(form.DynamicList, 'domain_whitelist', _('Domain Whitelist'),
			_('Domains that should always be routed through the proxy (one per line).'));
		o.optional = true;

		// ─── Секция: HWID ───
		s = m.section(form.TypedSection, 'system', _('Device Identity'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'hwid', _('HWID'),
			_('Hardware ID used for subscription authentication.'));
		o.datatype = 'string';
		o.readonly = false;

		// ─── Обработка сохранения: пишем в /etc/xray/settings.json ───
		m.handleSave = function (ev) {
			// Собираем данные из формы
			var data = {
				url: m.lookupOption('subscription', 'url')[0].getValue() || '',
				user_agent: m.lookupOption('subscription', 'user_agent')[0].getValue() || 'XPower/1.0',
				remarks_filter: m.lookupOption('subscription', 'remarks_filter')[0].getValue() || '',
				domain_whitelist: m.lookupOption('subscription', 'domain_whitelist')[0].getValue() || []
			};

			var hwidVal = m.lookupOption('system', 'hwid')[0].getValue() || '';
			if (hwidVal) {
				data.hwid = hwidVal;
			}

			// Читаем текущий settings.json
			return fs.read('/etc/xray/settings.json').then(function (raw) {
				var current = {};
				try { current = JSON.parse(raw || '{}'); } catch(e) {}

				// Мержим
				if (!current.subscription) current.subscription = {};
				var sub = current.subscription;
				sub.url = data.url;
				sub.user_agent = data.user_agent;
				sub.remarks_filter = data.remarks_filter;
				sub.domain_whitelist = data.domain_whitelist;

				if (data.hwid) {
					current.hwid = data.hwid;
				}

				// Пишем обратно
				return fs.write('/etc/xray/settings.json', JSON.stringify(current, null, 2));
			}).then(function () {
				ui.addNotification(null, E('p', _('Settings saved successfully!')), 'info');
				// Пытаемся запустить обновление
				return fs.exec('/usr/share/xray/update-xray.sh', ['--background']);
			}).catch(function (err) {
				ui.addNotification(null, E('p', _('Failed to save settings: ') + err), 'error');
			});
		};

		// ─── Загрузка данных из settings.json ───
		m.handleLoad = function () {
			return fs.read('/etc/xray/settings.json').then(function (raw) {
				var data = {};
				try { data = JSON.parse(raw || '{}'); } catch (e) {}

				var sub = data.subscription || {};
				return {
					subscription: {
						url: sub.url || '',
						user_agent: sub.user_agent || 'XPower/1.0',
						remarks_filter: sub.remarks_filter || '',
						domain_whitelist: sub.domain_whitelist || []
					},
					system: {
						hwid: data.hwid || ''
					}
				};
			});
		};

		return m.render();
	}
});
