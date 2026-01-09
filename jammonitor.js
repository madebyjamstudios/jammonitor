// ===== INTERNATIONALIZATION (i18n) =====
var JM_TRANSLATIONS = {};
var JM_LANG = 'en';

// Translation function - call as _('string') or _('string with %s', value)
function _(key) {
    var translated = JM_TRANSLATIONS[key] || key;
    if (arguments.length > 1) {
        var args = Array.prototype.slice.call(arguments, 1);
        var i = 0;
        translated = translated.replace(/%[sd]/g, function() {
            return args[i++] !== undefined ? args[i - 1] : '';
        });
    }
    return translated;
}

// Detect language from localStorage override or browser setting
function detectLanguage() {
    var saved = localStorage.getItem('jammonitor_lang');
    if (saved && saved !== 'auto') return saved;

    var browserLang = navigator.language || navigator.userLanguage || 'en';
    var langMap = {
        'zh': 'zh-cn', 'zh-CN': 'zh-cn', 'zh-TW': 'zh-cn',
        'es': 'es', 'de': 'de', 'fr': 'fr', 'pt': 'pt-br',
        'pt-BR': 'pt-br', 'ru': 'ru', 'ja': 'ja', 'it': 'it',
        'nl': 'nl', 'pl': 'pl', 'ko': 'ko', 'tr': 'tr',
        'vi': 'vi', 'ar': 'ar', 'th': 'th', 'id': 'id',
        'cs': 'cs', 'sv': 'sv', 'el': 'el', 'uk': 'uk'
    };
    var shortLang = browserLang.split('-')[0];
    return langMap[browserLang] || langMap[shortLang] || 'en';
}

// Load translations for detected/selected language
function loadTranslations() {
    var lang = detectLanguage();
    if (window.JM_I18N && window.JM_I18N[lang]) {
        JM_TRANSLATIONS = window.JM_I18N[lang];
        JM_LANG = lang;
    }
}

// Initialize i18n on script load
loadTranslations();

// Debug: log translation status
console.log('[i18n] Language detected:', detectLanguage());
console.log('[i18n] JM_I18N available:', !!window.JM_I18N);
console.log('[i18n] Translations loaded:', Object.keys(JM_TRANSLATIONS).length, 'strings');

// Translate static HTML elements on page load
function translatePage() {
    console.log('[i18n] translatePage() running, JM_TRANSLATIONS has', Object.keys(JM_TRANSLATIONS).length, 'keys');
    // Translate elements with data-i18n attribute
    document.querySelectorAll('[data-i18n]').forEach(function(el) {
        var key = el.getAttribute('data-i18n');
        if (key && JM_TRANSLATIONS[key]) {
            el.textContent = JM_TRANSLATIONS[key];
        }
    });

    // Translate sidebar items by their text content
    document.querySelectorAll('.jm-sidebar-item, .jm-sidebar-section').forEach(function(el) {
        var key = el.textContent.trim();
        if (key && JM_TRANSLATIONS[key]) {
            el.textContent = JM_TRANSLATIONS[key];
        }
    });

    // Translate page titles (h2 elements)
    document.querySelectorAll('h2').forEach(function(el) {
        var key = el.textContent.trim();
        if (key && JM_TRANSLATIONS[key]) {
            el.textContent = JM_TRANSLATIONS[key];
        }
    });

    // Translate block titles
    document.querySelectorAll('.jm-block-title').forEach(function(el) {
        var key = el.textContent.trim();
        if (key && JM_TRANSLATIONS[key]) {
            el.textContent = JM_TRANSLATIONS[key];
        }
    });

    // Translate labels
    document.querySelectorAll('.jm-label').forEach(function(el) {
        var key = el.textContent.trim();
        if (key && JM_TRANSLATIONS[key]) {
            el.textContent = JM_TRANSLATIONS[key];
        }
    });

    // Translate button text
    document.querySelectorAll('button').forEach(function(el) {
        var key = el.textContent.trim();
        if (key && JM_TRANSLATIONS[key]) {
            el.textContent = JM_TRANSLATIONS[key];
        }
    });

    // Translate table headers
    document.querySelectorAll('th').forEach(function(el) {
        var key = el.textContent.trim().replace(/[▲▼↑↓]/g, '').trim();
        if (key && JM_TRANSLATIONS[key]) {
            // Preserve sort arrows if present
            var arrow = el.textContent.match(/[▲▼↑↓]/);
            el.textContent = JM_TRANSLATIONS[key] + (arrow ? ' ' + arrow[0] : '');
        }
    });
}

// Run translation when DOM is ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', translatePage);
} else {
    translatePage();
}

// ===== END i18n =====

var JamMonitor = (function() {
    'use strict';

    var STORAGE_KEY = 'jammonitor';
    var currentView = 'overview';
    var updateTimer = null;
    var scale = 'mb'; // mb or gb
    var selectedIface = 'all';

    // Ping targets
    var pingTargets = {
        inet: '1.1.1.1',
        vps: null,
        tunnel: null
    };

    // Ping history with loss tracking
    var pingHistory = { inet: [], vps: [], tunnel: [] };
    var pingStats = {
        inet: { sent: 0, received: 0 },
        vps: { sent: 0, received: 0 },
        tunnel: { sent: 0, received: 0 }
    };
    var maxPingHistory = 120; // ~6 min at 3s interval

    // Bandwidth data
    var bwHistory = [];
    var maxBwHistory = 120;
    var lastBwBytes = {};
    var throughputHistory = [];

    // Storage status cache for diagnostics
    var storageStatusCache = null;

    // Interface list
    var interfaces = [];

    // WAN Policy data
    var wanPolicyData = [];
    var wanPolicyModes = {};
    var wanPolicyPollTimer = null;
    var wanPolicyPollEnd = 0;

    // VPS Bypass state
    var bypassEnabled = false;
    var bypassActiveWan = null;
    var bypassToggling = false;

    // Client metadata and DHCP reservations
    var clientMeta = {};      // {mac: {alias, type}}
    var reservedMacs = {};    // {mac: {ip, name, mac}}

    // Pending changes (not yet saved)
    var pendingMeta = {};           // {mac: {alias, type}} - pending name/type changes
    var pendingReservations = {};   // {mac: {ip, name, action: 'add'|'update'|'remove'}}

    // Client list sorting and grouping state
    var clientSortColumn = 'ip';
    var clientSortDirection = 'asc';
    var collapsedGroups = {};       // { '10.10.10': true } - collapsed subnet groups
    var clientsDataCache = null;    // Cache parsed client data for re-sorting

    // Speed test state
    var speedTestSize = 10;          // Default 10MB
    var speedTestResults = {};       // {wan1: {download: {...}, upload: {...}}, ...}
    var speedTestRunning = {};       // {wan1_download: job_id, ...}

    // Check if interface is a WAN or VPN (for bandwidth tracking)
    // OMR naming: lan1/2/3/4 are WANs, sfp-lan is SFP WAN, tun0 is VPN tunnel
    // Note: "wan" and "sfp-wan" are actually LAN ports in OMR, not WANs
    function isWanInterface(iface) {
        if (!iface) return false;
        return iface.match(/^lan[0-9]/) ||
               iface === 'sfp-lan' ||
               iface === 'tun0';  // VPN tunnel
    }

    function init() {
        loadState();

        // Language selector handler
        var langSelect = document.getElementById('jm-lang-select');
        if (langSelect) {
            // Set current value from localStorage
            var savedLang = localStorage.getItem('jammonitor_lang') || 'auto';
            langSelect.value = savedLang;
            // Handle change
            langSelect.addEventListener('change', function() {
                localStorage.setItem('jammonitor_lang', this.value);
                location.reload();
            });
        }

        document.querySelectorAll('.jm-sidebar-item').forEach(function(item) {
            item.addEventListener('click', function() {
                switchView(this.dataset.view);
            });
        });

        // Restore view from URL hash or localStorage
        var hashView = window.location.hash.replace('#tab=', '');
        if (hashView && document.getElementById('view-' + hashView)) {
            switchView(hashView);
        } else {
            var savedView = localStorage.getItem(STORAGE_KEY + '_view');
            if (savedView && document.getElementById('view-' + savedView)) {
                switchView(savedView);
            } else {
                switchView('overview');
            }
        }

        // Listen for hash changes
        window.addEventListener('hashchange', function() {
            var newHash = window.location.hash.replace('#tab=', '');
            if (newHash && newHash !== currentView && document.getElementById('view-' + newHash)) {
                switchView(newHash);
            }
        });

        // Detect endpoints and interfaces
        detectEndpoints();
        detectInterfaces();

        // Load client metadata and reservations
        loadClientMeta();
        loadReservations();

        // Client list click handlers (with safety check)
        var clientsTbody = document.getElementById('clients-tbody');
        if (clientsTbody) {
            clientsTbody.addEventListener('click', function(e) {
                // Inline edit - Save button (saves to pending, not config)
                if (e.target.classList.contains('btn-save')) {
                    var cell = e.target.closest('.client-name');
                    var mac = cell && cell.dataset.mac;
                    if (!mac) return;
                    var input = cell.querySelector('.name-edit input');
                    var newName = input.value.trim();
                    var originalName = input.dataset.original;
                    if (newName && newName !== originalName) {
                        if (!pendingMeta[mac.toLowerCase()]) pendingMeta[mac.toLowerCase()] = {};
                        pendingMeta[mac.toLowerCase()].alias = newName;
                        cell.querySelector('.name-display').textContent = newName;
                        input.dataset.original = newName;
                        cell.classList.add('client-pending-name');
                        updatePendingUI();
                    }
                    cell.classList.remove('editing');
                    var row = cell.closest('tr');
                    if (row) row.classList.remove('row-editing');
                    cell.classList.add('cancelled');
                    cell.addEventListener('mouseleave', function handler() {
                        cell.classList.remove('cancelled');
                        cell.removeEventListener('mouseleave', handler);
                    });
                    return;
                }
                // Inline edit - Cancel button
                if (e.target.classList.contains('btn-cancel')) {
                    var cell = e.target.closest('.client-name');
                    if (cell) {
                        var input = cell.querySelector('.name-edit input');
                        input.value = input.dataset.original;
                        cell.classList.remove('editing');
                        var row = cell.closest('tr');
                        if (row) row.classList.remove('row-editing');
                        cell.classList.add('cancelled');
                        cell.addEventListener('mouseleave', function handler() {
                            cell.classList.remove('cancelled');
                            cell.removeEventListener('mouseleave', handler);
                        });
                    }
                    return;
                }
                // Click on input - add editing class to keep form visible
                if (e.target.matches('.name-edit input')) {
                    var cell = e.target.closest('.client-name');
                    if (cell) {
                        cell.classList.add('editing');
                        var row = cell.closest('tr');
                        if (row) row.classList.add('row-editing');
                    }
                    return;
                }
                // Reservation popup
                var resTag = e.target.closest('.reservation-tag');
                if (resTag && resTag.dataset.mac) {
                    showReservationPopup(resTag.dataset.mac, resTag.dataset.ip, resTag.dataset.name);
                }
            });
        } else {
            console.error('JamMonitor: clients-tbody not found');
        }

        // Start polling
        startPolling();

        // Save state periodically
        setInterval(saveState, 10000);
    }

    function loadState() {
        try {
            var saved = localStorage.getItem(STORAGE_KEY + '_data');
            if (saved) {
                var data = JSON.parse(saved);
                if (data.pingHistory) pingHistory = data.pingHistory;
                if (data.pingStats) pingStats = data.pingStats;
                if (data.bwHistory) bwHistory = data.bwHistory;
                if (data.throughputHistory) throughputHistory = data.throughputHistory;
                if (data.pingTargets) {
                    if (data.pingTargets.vps) pingTargets.vps = data.pingTargets.vps;
                    if (data.pingTargets.tunnel) pingTargets.tunnel = data.pingTargets.tunnel;
                }
            }
        } catch (e) { console.error('Failed to load state:', e); }
    }

    function saveState() {
        try {
            var data = {
                pingHistory: pingHistory,
                pingStats: pingStats,
                bwHistory: bwHistory.slice(-maxBwHistory),
                throughputHistory: throughputHistory.slice(-maxBwHistory),
                pingTargets: pingTargets,
                timestamp: Date.now()
            };
            localStorage.setItem(STORAGE_KEY + '_data', JSON.stringify(data));
        } catch (e) { console.error('Failed to save state:', e); }
    }

    function switchView(view) {
        currentView = view;
        localStorage.setItem(STORAGE_KEY + '_view', view);

        // Update URL hash for bookmarkable tabs
        if (window.location.hash !== '#tab=' + view) {
            history.replaceState(null, null, '#tab=' + view);
        }

        document.querySelectorAll('.jm-sidebar-item').forEach(function(el) {
            el.classList.toggle('active', el.dataset.view === view);
        });
        document.querySelectorAll('.jm-view').forEach(function(el) {
            el.classList.toggle('active', el.id === 'view-' + view);
        });

        // Sync scale buttons to current scale state
        document.querySelectorAll('.jm-scale-btn').forEach(function(btn) {
            btn.classList.toggle('active', btn.dataset.scale === scale);
        });

        if (view === 'overview') updateOverview();
        else if (view === 'wan-policy') loadWanPolicy();
        else if (view === 'links') updateLinks();
        else if (view === 'clients') updateClients();
        else if (view === 'wifi-aps') updateWifiAps();
        else if (view === 'omr-status') loadOmrStatus();
        else if (view === 'diagnostics') { checkStorageSetup(); loadStorageStatus(); populateSpeedTestWans(); }
        else if (view.startsWith('bw-')) updateBandwidth(view);
    }

    function startPolling() {
        if (updateTimer) clearInterval(updateTimer);
        updateTimer = setInterval(function() {
            if (currentView === 'overview') updateOverview();
            else if (currentView === 'wan-policy') loadWanPolicy(true);
            else if (currentView === 'clients') updateClients();
            else if (currentView === 'wifi-aps') updateWifiAps();
            else if (currentView === 'bw-realtime') updateBandwidth('bw-realtime');
        }, 5000);

        // Always collect data in background
        setInterval(collectBackgroundData, 3000);
    }

    function collectBackgroundData() {
        // Always run pings for history
        doPing(pingTargets.inet, 'inet');
        if (pingTargets.vps) doPing(pingTargets.vps, 'vps');
        if (pingTargets.tunnel) doPing(pingTargets.tunnel, 'tunnel');

        // Always collect throughput
        collectThroughput();
    }

    // === SECURE API FUNCTIONS ===
    // These replace the generic exec() function with specific endpoints

    function api(endpoint, params) {
        var url = window.location.pathname + '/' + endpoint;
        if (params) {
            var queryString = Object.keys(params).map(function(k) {
                return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
            }).join('&');
            url += '?' + queryString;
        }
        return fetch(url)
            .then(function(r) {
                if (!r.ok) throw new Error('API error: ' + r.status);
                return r.json();
            })
            .catch(function(e) {
                console.error('API error (' + endpoint + '):', e);
                return null;
            });
    }

    function apiPing(host) {
        return api('ping', { host: host });
    }

    // Cache for CPU calculation (need two samples)
    var lastCpuSample = null;

    function detectEndpoints() {
        // Use the new vpn_status endpoint
        api('vpn_status').then(function(data) {
            if (!data) return;

            // VPS IP from WireGuard endpoint or UCI config
            if (data.wireguard && data.wireguard.endpoint) {
                pingTargets.vps = data.wireguard.endpoint;
                document.getElementById('ping-vps-target').textContent = pingTargets.vps;
            } else if (data.vps && data.vps.ip) {
                pingTargets.vps = data.vps.ip;
                document.getElementById('ping-vps-target').textContent = data.vps.ip;
            }

            // Tunnel peer IP
            if (data.tunnel) {
                var tunnelIp = data.tunnel.gateway || data.tunnel.peer;
                if (tunnelIp) {
                    pingTargets.tunnel = tunnelIp;
                    document.getElementById('ping-tunnel-target').textContent = tunnelIp;
                } else if (data.tunnel.ip) {
                    // Fallback: use .1 of the tun0 subnet
                    var parts = data.tunnel.ip.split('.');
                    if (parts.length === 4) {
                        parts[3] = '1';
                        pingTargets.tunnel = parts.join('.');
                        document.getElementById('ping-tunnel-target').textContent = pingTargets.tunnel;
                    }
                }
            }
        });
    }

    function detectInterfaces() {
        api('network_info').then(function(data) {
            if (!data || !data.interfaces) return;

            interfaces = data.interfaces.map(function(iface) {
                // Strip @... suffix
                return iface.split('@')[0];
            });

            // Filter to WAN-like interfaces for bandwidth dropdowns
            var wanIfaces = interfaces.filter(isWanInterface);

            // Remove duplicates
            wanIfaces = wanIfaces.filter(function(iface, idx, arr) {
                return arr.indexOf(iface) === idx;
            });

            // If no WANs detected, show all physical interfaces as fallback
            if (wanIfaces.length === 0) {
                wanIfaces = interfaces.filter(function(iface) {
                    return iface && !iface.match(/^(lo|docker|veth|br-|tun|wg|ifb)/);
                });
            }

            // Populate all interface selects using safe DOM methods
            ['bw-iface-select', 'bw-hourly-iface', 'bw-daily-iface', 'bw-monthly-iface'].forEach(function(id) {
                var sel = document.getElementById(id);
                if (sel) {
                    sel.innerHTML = '';
                    var optAll = document.createElement('option');
                    optAll.value = 'all';
                    optAll.textContent = _('All WANs');
                    sel.appendChild(optAll);
                    wanIfaces.forEach(function(iface) {
                        if (iface) {
                            var opt = document.createElement('option');
                            opt.value = iface;
                            opt.textContent = iface;
                            sel.appendChild(opt);
                        }
                    });
                }
            });
        }).catch(function(e) {
            console.error('detectInterfaces error:', e);
        });
    }

    function updateOverview() {
        // Use system_stats API for all system metrics
        api('system_stats').then(function(data) {
            if (!data) return;

            // Load average
            if (data.load && data.load.length >= 3) {
                document.getElementById('sys-load').textContent = data.load[0] + ' / ' + data.load[1] + ' / ' + data.load[2];
            }

            // CPU % - calculate delta from last sample
            if (data.cpu_busy !== undefined && data.cpu_idle !== undefined) {
                if (lastCpuSample) {
                    var busyDiff = data.cpu_busy - lastCpuSample.busy;
                    var idleDiff = data.cpu_idle - lastCpuSample.idle;
                    var total = busyDiff + idleDiff;
                    if (total > 0) {
                        var cpu = (busyDiff / total) * 100;
                        document.getElementById('sys-cpu').textContent = cpu.toFixed(1) + '%';
                    }
                }
                lastCpuSample = { busy: data.cpu_busy, idle: data.cpu_idle };
            }

            // Temperature
            if (data.temp !== undefined) {
                document.getElementById('sys-temp-big').textContent = data.temp.toFixed(1) + ' C';
                var ind = document.getElementById('sys-indicator');
                if (data.temp > 80) ind.className = 'jm-indicator red';
                else if (data.temp > 65) ind.className = 'jm-indicator yellow';
                else ind.className = 'jm-indicator green';
            }

            // RAM
            if (data.ram_pct) {
                document.getElementById('sys-ram').textContent = data.ram_pct + '%';
            }

            // Conntrack
            if (data.conntrack_count !== undefined) {
                document.getElementById('sys-conntrack').textContent = data.conntrack_count + ' / ' + data.conntrack_max;
            }

            // Uptime
            if (data.uptime_secs) {
                document.getElementById('uptime-val').textContent = formatUptime(data.uptime_secs);
                document.getElementById('uptime-tooltip').textContent = _('Since boot');
            }

            // Date
            if (data.date) {
                document.getElementById('local-time').textContent = data.date;
            }
        });

        // VPN/Tunnel status using new API
        api('vpn_status').then(function(data) {
            if (!data) return;

            var vpnInd = document.getElementById('vpn-indicator');
            var vpnStatus = document.getElementById('vpn-status');
            var vpnIface = document.getElementById('vpn-iface');
            var vpnIp = document.getElementById('vpn-ip');
            var vpnEndpoint = document.getElementById('vpn-endpoint');
            var vpnHandshake = document.getElementById('vpn-handshake');

            // Check tunnel (tun0) first
            if (data.tunnel && data.tunnel.exists && data.tunnel.ip) {
                vpnInd.className = 'jm-indicator green';
                vpnStatus.textContent = _('Connected');
                vpnIface.textContent = 'tun0';
                vpnIp.textContent = data.tunnel.ip;

                if (data.vps && data.vps.ip) {
                    vpnEndpoint.textContent = data.vps.ip;
                }

                if (data.tunnel.omrvpn_uptime) {
                    var secs = data.tunnel.omrvpn_uptime;
                    var h = Math.floor(secs / 3600);
                    var m = Math.floor((secs % 3600) / 60);
                    vpnHandshake.textContent = h + 'h ' + m + 'm';
                } else {
                    vpnHandshake.textContent = _('Connected');
                }
            } else if (data.wireguard && data.wireguard.active) {
                // WireGuard fallback
                vpnInd.className = 'jm-indicator green';
                vpnStatus.textContent = _('Connected (WG)');
                vpnIface.textContent = data.wireguard.interface || 'wg0';
                vpnIp.textContent = data.wireguard.ip || 'N/A';
                if (data.wireguard.endpoint) {
                    vpnEndpoint.textContent = data.wireguard.endpoint;
                }
                vpnHandshake.textContent = _('Connected');
            } else {
                // No VPN connection
                vpnInd.className = 'jm-indicator red';
                vpnStatus.textContent = _('Disconnected');
                vpnIface.textContent = _('N/A');
                vpnIp.textContent = _('N/A');
                vpnEndpoint.textContent = data.vps && data.vps.ip ? data.vps.ip : _('N/A');
                vpnHandshake.textContent = _('N/A');
            }
        });

        // WAN info - get route and public IP using APIs
        api('network_info').then(function(data) {
            if (!data) return;

            // Parse default route
            var routeLines = (data.route || '').split('\n');
            var defaultRoute = routeLines.find(function(line) { return line.indexOf('default') === 0; });
            if (defaultRoute) {
                var gwMatch = defaultRoute.match(/via\s+(\S+)/);
                var devMatch = defaultRoute.match(/dev\s+(\S+)/);
                if (gwMatch) document.getElementById('wan-gw').textContent = gwMatch[1];
                if (devMatch) document.getElementById('wan-iface').textContent = devMatch[1];
            } else {
                document.getElementById('wan-indicator').className = 'jm-indicator red';
                document.getElementById('wan-status').textContent = _('No Route');
                document.getElementById('wan-ip').textContent = '--';
                document.getElementById('wan-gw').textContent = '--';
                document.getElementById('wan-iface').textContent = '--';
            }
        });

        // Get actual public IP from API
        api('public_ip').then(function(data) {
            if (data && data.success && data.ip) {
                document.getElementById('wan-ip').textContent = data.ip;
                document.getElementById('wan-indicator').className = 'jm-indicator green';
                document.getElementById('wan-status').textContent = _('Connected');
            } else {
                document.getElementById('wan-indicator').className = 'jm-indicator red';
                document.getElementById('wan-status').textContent = _('No Internet');
                document.getElementById('wan-ip').textContent = '--';
            }
        });

        // MPTCP status using API
        api('mptcp_status').then(function(data) {
            if (!data) return;

            var ind = document.getElementById('mptcp-indicator');
            if (data.endpoint_count > 0) {
                document.getElementById('mptcp-subflows').textContent = data.endpoint_count;
                ind.className = 'jm-indicator green';
            } else {
                document.getElementById('mptcp-subflows').textContent = '0';
                ind.className = 'jm-indicator gray';
            }

            if (data.connections !== undefined) {
                document.getElementById('mptcp-conns').textContent = data.connections + ' active';
            }

            if (data.interfaces) {
                document.getElementById('mptcp-ifaces').textContent = data.interfaces || 'none';
            }
        });

        // (MPTCP connections and interfaces now handled by mptcp_status API above)

        // Update ping displays
        updatePingDisplay('inet');
        updatePingDisplay('vps');
        updatePingDisplay('tunnel');

        // Update throughput display
        if (throughputHistory.length > 0) {
            var last = throughputHistory[throughputHistory.length - 1];
            document.getElementById('tp-down').textContent = formatRate(last.rx);
            document.getElementById('tp-up').textContent = formatRate(last.tx);
            drawThroughputGraph();
        }
    }

    function doPing(host, key) {
        if (!host) return;

        pingStats[key].sent++;

        // Use the secure ping API endpoint
        apiPing(host).then(function(data) {
            if (data && data.success && data.latency) {
                pingStats[key].received++;
                pingHistory[key].push({ time: Date.now(), value: data.latency });
            } else {
                pingHistory[key].push({ time: Date.now(), value: null });
            }

            if (pingHistory[key].length > maxPingHistory) pingHistory[key].shift();

            // Only update display if on overview
            if (currentView === 'overview') {
                updatePingDisplay(key);
            }
        });
    }

    function updatePingDisplay(key) {
        var history = pingHistory[key];
        var stats = pingStats[key];
        var valEl = document.getElementById('ping-' + key + '-val');
        var indEl = document.getElementById('ping-' + key + '-indicator');
        var lossEl = document.getElementById('ping-' + key + '-loss');
        var targetEl = document.getElementById('ping-' + key + '-target');

        // Update target display
        if (pingTargets[key]) {
            targetEl.textContent = pingTargets[key];
        }

        // Calculate loss percentage using rolling window (last ~6 min)
        var loss = 0;
        if (history.length > 0) {
            var failures = 0;
            for (var k = 0; k < history.length; k++) {
                if (history[k].value === null) failures++;
            }
            loss = (failures / history.length) * 100;
        }
        lossEl.textContent = loss.toFixed(1) + '%';

        // Count consecutive recent failures (check last 2 pings)
        var recentFailures = 0;
        for (var j = history.length - 1; j >= 0 && j >= history.length - 2; j--) {
            if (history[j].value === null) recentFailures++;
        }

        // Get latest successful value
        var latest = null;
        for (var i = history.length - 1; i >= 0; i--) {
            if (history[i].value !== null) {
                latest = history[i].value;
                break;
            }
        }

        // Show red immediately if 2+ consecutive failures (faster response)
        if (recentFailures >= 2) {
            valEl.textContent = _('timeout');
            indEl.className = 'jm-indicator red';
        } else if (history.length > 0 && history[history.length - 1].value === null) {
            // Single failure - show yellow warning
            valEl.textContent = latest !== null ? latest.toFixed(1) + '*' : 'timeout';
            indEl.className = 'jm-indicator yellow';
        } else if (latest !== null) {
            valEl.textContent = latest.toFixed(1);
            if (latest < 50 && loss < 5) indEl.className = 'jm-indicator green';
            else if (latest < 150 && loss < 20) indEl.className = 'jm-indicator yellow';
            else indEl.className = 'jm-indicator red';
        } else {
            valEl.textContent = _('timeout');
            indEl.className = 'jm-indicator red';
        }

        // Draw graph
        drawMiniGraph('graph-ping-' + key, history.map(function(h) { return h.value; }), '#3498db');
    }

    // Per-interface throughput history
    var ifaceThroughputHistory = {};

    function collectThroughput() {
        api('network_info').then(function(data) {
            if (!data || !data.netdev) return;
            var out = data.netdev;
            var totalRx = 0, totalTx = 0;
            var now = Date.now();

            out.split('\n').forEach(function(line) {
                if (line.indexOf(':') < 0) return;
                var parts = line.trim().split(/\s+/);
                var iface = parts[0].replace(':', '');
                if (!iface || iface === 'lo' || iface.indexOf('docker') >= 0 || iface.indexOf('veth') >= 0) return;

                var rx = parseInt(parts[1], 10);
                var tx = parseInt(parts[9], 10);

                if (lastBwBytes[iface]) {
                    var dt = (now - lastBwBytes[iface].time) / 1000;
                    if (dt > 0 && dt < 60) { // Sanity check: ignore if more than 60s gap
                        var ifaceRx = (rx - lastBwBytes[iface].rx) / dt;
                        var ifaceTx = (tx - lastBwBytes[iface].tx) / dt;

                        // Ignore negative values (counter reset)
                        if (ifaceRx < 0) ifaceRx = 0;
                        if (ifaceTx < 0) ifaceTx = 0;

                        // Store per-interface history
                        if (!ifaceThroughputHistory[iface]) ifaceThroughputHistory[iface] = [];
                        ifaceThroughputHistory[iface].push({
                            time: now,
                            rx: ifaceRx,
                            tx: ifaceTx
                        });
                        if (ifaceThroughputHistory[iface].length > maxBwHistory) {
                            ifaceThroughputHistory[iface].shift();
                        }

                        // Count WANs in total (use shared function)
                        if (isWanInterface(iface)) {
                            totalRx += ifaceRx;
                            totalTx += ifaceTx;
                        }
                    }
                }
                lastBwBytes[iface] = { rx: rx, tx: tx, time: now };
            });

            // Always push to history so graph updates
            throughputHistory.push({
                time: now,
                rx: Math.max(0, totalRx),
                tx: Math.max(0, totalTx)
            });
            if (throughputHistory.length > maxBwHistory) throughputHistory.shift();
        }).catch(function(e) {
            console.error('collectThroughput error:', e);
        });
    }

    function getFilteredThroughput() {
        if (selectedIface === 'all') {
            return throughputHistory;
        } else if (ifaceThroughputHistory[selectedIface]) {
            return ifaceThroughputHistory[selectedIface];
        }
        return throughputHistory;
    }

    function drawMiniGraph(canvasId, data, color) {
        var canvas = document.getElementById(canvasId);
        if (!canvas) return;

        var rect = canvas.getBoundingClientRect();
        var ctx = canvas.getContext('2d');
        canvas.width = rect.width * 2;
        canvas.height = rect.height * 2;
        ctx.scale(2, 2);
        var w = rect.width, h = rect.height;

        ctx.clearRect(0, 0, w, h);
        if (data.length < 2) return;

        var max = 0;
        var validData = data.filter(function(v) { return v !== null; });
        validData.forEach(function(v) { if (v > max) max = v; });
        if (max === 0) max = 100;
        max = max * 1.2;

        // Grid
        ctx.strokeStyle = '#ecf0f1';
        ctx.lineWidth = 1;
        for (var i = 1; i < 3; i++) {
            var gy = (h / 3) * i;
            ctx.beginPath();
            ctx.moveTo(0, gy);
            ctx.lineTo(w, gy);
            ctx.stroke();
        }

        // Line
        ctx.strokeStyle = color;
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        var step = w / (maxPingHistory - 1);
        var started = false;

        for (var j = 0; j < data.length; j++) {
            var v = data[j];
            if (v === null) continue;
            var x = j * step;
            var y = h - (v / max) * (h - 4) - 2;
            if (!started) { ctx.moveTo(x, y); started = true; }
            else ctx.lineTo(x, y);
        }
        ctx.stroke();

        // Fill
        if (started && data.length > 1) {
            var lastIdx = data.length - 1;
            ctx.lineTo(lastIdx * step, h);
            ctx.lineTo(0, h);
            ctx.closePath();
            ctx.fillStyle = 'rgba(52, 152, 219, 0.15)';
            ctx.fill();
        }
    }

    function drawThroughputGraph() {
        var canvas = document.getElementById('graph-throughput');
        if (!canvas) return;

        var rect = canvas.getBoundingClientRect();
        var ctx = canvas.getContext('2d');
        canvas.width = rect.width * 2;
        canvas.height = rect.height * 2;
        ctx.scale(2, 2);
        var w = rect.width, h = rect.height;

        ctx.clearRect(0, 0, w, h);
        if (throughputHistory.length < 2) return;

        var max = 0;
        throughputHistory.forEach(function(d) {
            if (d.rx > max) max = d.rx;
            if (d.tx > max) max = d.tx;
        });
        if (max === 0) max = 1000;
        max = max * 1.2;

        var step = w / (maxBwHistory - 1);

        // RX line
        ctx.strokeStyle = '#27ae60';
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        throughputHistory.forEach(function(d, i) {
            var x = i * step;
            var y = h - (d.rx / max) * (h - 4) - 2;
            if (i === 0) ctx.moveTo(x, y);
            else ctx.lineTo(x, y);
        });
        ctx.stroke();

        // TX line
        ctx.strokeStyle = '#e74c3c';
        ctx.beginPath();
        throughputHistory.forEach(function(d, i) {
            var x = i * step;
            var y = h - (d.tx / max) * (h - 4) - 2;
            if (i === 0) ctx.moveTo(x, y);
            else ctx.lineTo(x, y);
        });
        ctx.stroke();
    }

    function updateLinks() {
        var grid = document.getElementById('iface-grid');
        var routeDiv = document.getElementById('routing-table');

        // Hide internal/virtual/kernel tunnel interfaces (prefix match)
        var hiddenPrefixes = ['lo', 'ifb', 'teql', 'gre', 'sit', 'ip6tnl', 'ip6gre', 'erspan', 'dummy', 'ip_vti', 'ip6_vti', 'gretap'];

        api('network_info').then(function(data) {
            if (!data) {
                console.error('updateLinks: No data from network_info API');
                grid.innerHTML = '<p style="color:#999;">Failed to load interface data</p>';
                return;
            }
            // Map API response to expected array format for backward compatibility
            var results = [
                data.link || '',
                data.addr || '',
                data.route || '',
                data.netdev || '',
                data.phy_devices || '',
                data.wireless_config || ''
            ];
            var linkLines = results[0].trim().split('\n');
            var addrLines = results[1].trim().split('\n');
            var devStats = {};
            var phyDevices = results[4].trim().split('\n').filter(function(r) { return r && r.trim(); });

            // Parse UCI wireless output to get radio names and disabled status
            var uciRadioInfo = {};
            results[5].trim().split('\n').forEach(function(line) {
                if (!line) return;
                // Match "wireless.radio0=wifi-device"
                var deviceMatch = line.match(/wireless\.([^=]+)=wifi-device/);
                if (deviceMatch) {
                    var radioName = deviceMatch[1];
                    if (!uciRadioInfo[radioName]) {
                        uciRadioInfo[radioName] = { name: radioName, disabled: false };
                    }
                }
                // Match "wireless.radio0.disabled='1'"
                var disabledMatch = line.match(/wireless\.([^.]+)\.disabled='?([^']*)'?/);
                if (disabledMatch) {
                    var radioName = disabledMatch[1];
                    var disabledVal = disabledMatch[2];
                    if (!uciRadioInfo[radioName]) {
                        uciRadioInfo[radioName] = { name: radioName, disabled: false };
                    }
                    uciRadioInfo[radioName].disabled = (disabledVal === '1' || disabledVal === 'true');
                }
            });
            var uciRadios = Object.values(uciRadioInfo);

            // Parse /proc/net/dev for stats
            results[3].split('\n').forEach(function(line) {
                if (line.indexOf(':') < 0) return;
                var parts = line.trim().split(/\s+/);
                var iface = parts[0].replace(':', '');
                devStats[iface] = {
                    rxBytes: parseInt(parts[1], 10),
                    txBytes: parseInt(parts[9], 10)
                };
            });

            // Build address map
            var addrMap = {};
            addrLines.forEach(function(line) {
                var parts = line.trim().split(/\s+/);
                if (parts.length >= 3) {
                    addrMap[parts[0]] = parts.slice(2).join(' ');
                }
            });

            // Categorize interfaces
            var wans = [], lans = [], vpns = [], radios = [], bridges = [], physical = [];

            linkLines.forEach(function(line) {
                var parts = line.trim().split(/\s+/);
                if (parts.length < 2) return;
                var iface = parts[0];
                var state = parts[1];
                var mac = parts[2] || '';

                // Skip hidden interfaces (prefix match)
                var shouldHide = false;
                var ifaceBase = iface.split('@')[0]; // Strip @NONE suffix
                hiddenPrefixes.forEach(function(prefix) {
                    if (ifaceBase === prefix || ifaceBase.indexOf(prefix) === 0) {
                        shouldHide = true;
                    }
                });
                if (shouldHide) return;
                if (iface.indexOf('docker') >= 0 || iface.indexOf('veth') >= 0) return;

                // Handle VLAN interfaces (eth0@if2 -> eth0)
                var displayName = iface;
                if (iface.indexOf('@') >= 0) {
                    displayName = iface.split('@')[0];
                }

                // Tunnels report 'UNKNOWN' state, not 'UP' - also consider having an IP as "up"
                var hasAddr = addrMap[iface] || addrMap[displayName];
                var isUp = state.indexOf('UP') >= 0 || state.indexOf('UNKNOWN') >= 0 || !!hasAddr;
                var addr = hasAddr || _('None');
                var stats = devStats[iface] || devStats[displayName] || { rxBytes: 0, txBytes: 0 };

                var ifaceData = {
                    name: iface,
                    displayName: displayName,
                    state: state,
                    isUp: isUp,
                    mac: mac,
                    addr: addr,
                    stats: stats
                };

                // Categorize - OMR naming: lan1/2/3/4 are WANs (DHCP), wan/sfp-wan are physical LAN ports
                if (iface.match(/^lan[0-9]/) || iface === 'sfp-lan') {
                    ifaceData.type = 'WAN';
                    wans.push(ifaceData);
                } else if (iface === 'wan' || iface.indexOf('wan@') === 0 || iface === 'sfp-wan' || iface === 'br-wan') {
                    ifaceData.type = 'LAN';
                    lans.push(ifaceData);
                } else if (iface.match(/^(tun|wg|mlvpn|omrvpn)/)) {
                    ifaceData.type = 'VPN';
                    vpns.push(ifaceData);
                } else if (iface.match(/^(wlan|phy|radio|ra[0-9]|rai|apcli)/)) {
                    ifaceData.type = 'WiFi';
                    radios.push(ifaceData);
                } else if (iface.indexOf('br-') === 0) {
                    ifaceData.type = 'Bridge';
                    bridges.push(ifaceData);
                } else if (iface.match(/^(eth|sfp)/)) {
                    ifaceData.type = 'Physical';
                    physical.push(ifaceData);
                } else {
                    // Include other interfaces in physical
                    ifaceData.type = 'Other';
                    physical.push(ifaceData);
                }
            });

            // Sort WANs: lan1, lan2, lan3, then sfp-lan
            wans.sort(function(a, b) {
                if (a.name === 'sfp-lan') return 1;
                if (b.name === 'sfp-lan') return -1;
                return a.name.localeCompare(b.name);
            });

            // Sort LANs: br-wan first, then wan, then sfp-wan
            lans.sort(function(a, b) {
                var order = { 'br-wan': 0, 'wan': 1, 'sfp-wan': 2 };
                var aBase = a.name.split('@')[0];
                var bBase = b.name.split('@')[0];
                var aOrder = order[aBase] !== undefined ? order[aBase] : (aBase.indexOf('wan') === 0 ? 1 : 10);
                var bOrder = order[bBase] !== undefined ? order[bBase] : (bBase.indexOf('wan') === 0 ? 1 : 10);
                return aOrder - bOrder;
            });

            // Add phy devices (phy0, phy1, etc.) if not already captured
            phyDevices.forEach(function(phy) {
                if (!phy) return;
                var exists = radios.some(function(r) { return r.name === phy; });
                if (!exists) {
                    radios.push({
                        name: phy,
                        displayName: phy,
                        type: 'Radio',
                        isUp: true,
                        addr: 'N/A',
                        stats: { rxBytes: 0, txBytes: 0 }
                    });
                }
            });

            // Add UCI radio devices (radio0, radio1, radio2) with actual status
            uciRadios.forEach(function(radioInfo) {
                if (!radioInfo || !radioInfo.name) return;
                var exists = radios.some(function(r) { return r.name === radioInfo.name; });
                if (!exists) {
                    radios.push({
                        name: radioInfo.name,
                        displayName: radioInfo.name,
                        type: 'Radio',
                        isUp: !radioInfo.disabled,
                        addr: radioInfo.disabled ? _('Disabled') : _('Enabled'),
                        stats: { rxBytes: 0, txBytes: 0 }
                    });
                }
            });

            // Sort radios by name
            radios.sort(function(a, b) { return a.name.localeCompare(b.name); });

            // Build HTML with sections - compact cards
            var html = '';

            function renderSection(title, ifaces, color) {
                if (ifaces.length === 0) return '';
                var borderColor = color || '#3498db';
                var s = '<div style="margin-bottom:15px;">';
                s += '<h3 style="color:#2c3e50;margin:0 0 8px;font-size:13px;border-bottom:2px solid ' + borderColor + ';padding-bottom:4px;">' + title + '</h3>';
                s += '<div class="jm-grid" style="grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap:8px;">';
                ifaces.forEach(function(iface) {
                    var indicatorClass = iface.isUp ? 'green' : 'red';
                    var stateText = iface.isUp ? _('UP') : _('DOWN');
                    var typeText = _(iface.type);
                    s += '<div class="jm-block-compact">';
                    s += '<div class="jm-block-header" style="margin-bottom:4px;padding-bottom:4px;">';
                    s += '<span class="jm-indicator ' + indicatorClass + '" style="width:8px;height:8px;"></span>';
                    s += '<span class="jm-block-title" style="font-size:12px;">' + escapeHtml(iface.name) + '</span>';
                    s += '<span class="jm-block-status" style="font-size:9px;">' + typeText + '</span>';
                    s += '</div>';
                    s += '<div class="jm-big-value">' + stateText + '</div>';
                    s += '<div class="jm-row"><span class="jm-label">' + _('IP') + '</span><span class="jm-value" style="font-size:10px;">' + escapeHtml((iface.addr || '').split(' ')[0] || _('None')) + '</span></div>';
                    s += '<div class="jm-row"><span class="jm-label">' + _('RX/TX') + '</span><span class="jm-value">' + formatBytesCompact(iface.stats.rxBytes) + '/' + formatBytesCompact(iface.stats.txBytes) + '</span></div>';
                    s += '</div>';
                });
                s += '</div></div>';
                return s;
            }

            // Order: WAN, LAN/Bridge, VPN/Tunnel, WiFi, Physical/Other
            html += renderSection(_('WAN Interfaces (DHCP)'), wans, '#e74c3c');
            html += renderSection(_('LAN / Bridge'), lans.concat(bridges), '#27ae60');
            html += renderSection(_('VPN / Tunnel'), vpns, '#9b59b6');
            html += renderSection(_('WiFi / Radios'), radios, '#f39c12');
            if (physical.length > 0) html += renderSection(_('Physical / Other'), physical, '#7f8c8d');

            grid.innerHTML = html || '<p style="color:#999;">' + _('No interfaces found') + '</p>';

            // Routing table
            var routes = results[2].trim().split('\n');
            var routeHtml = '<table style="width:100%;font-size:11px;">';
            routeHtml += '<tr style="background:#f5f5f5;"><th style="padding:5px;text-align:left;">' + _('Destination') + '</th><th style="padding:5px;">' + _('Gateway') + '</th><th style="padding:5px;">' + _('Interface') + '</th></tr>';
            routes.forEach(function(route, i) {
                var bg = i % 2 === 0 ? '#fff' : '#f9f9f9';
                var parts = route.split(/\s+/);
                var dest = parts[0] || '';
                var gw = '';
                var dev = '';
                for (var j = 0; j < parts.length; j++) {
                    if (parts[j] === 'via') gw = parts[j+1] || '';
                    if (parts[j] === 'dev') dev = parts[j+1] || '';
                }
                routeHtml += '<tr style="background:' + bg + ';">';
                routeHtml += '<td style="padding:5px;">' + escapeHtml(dest) + '</td>';
                routeHtml += '<td style="padding:5px;text-align:center;">' + escapeHtml(gw || '-') + '</td>';
                routeHtml += '<td style="padding:5px;text-align:center;">' + escapeHtml(dev) + '</td>';
                routeHtml += '</tr>';
            });
            routeHtml += '</table>';
            routeDiv.innerHTML = routeHtml;
        });
    }

    function formatBytesCompact(bytes) {
        if (bytes < 1024) return bytes + ' B';
        if (bytes < 1048576) return (bytes / 1024).toFixed(0) + ' KB';
        if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + ' MB';
        return (bytes / 1073741824).toFixed(1) + ' GB';
    }

    // Device type detection from hostname patterns (matches Peplink categories)
    function detectDeviceType(hostname) {
        if (!hostname || hostname === '*') return 'unknown';
        var patterns = {
            phone:     /iphone|android|galaxy|pixel|oneplus|redmi|poco|huawei-p|huawei-mate|sm-[gsa]/i,
            tablet:    /ipad|tablet|galaxy-tab|mediapad|sm-t|kindle-fire/i,
            laptop:    /macbook|laptop|notebook|thinkpad|dell-xps|surface-pro|surface-laptop|chromebook/i,
            desktop:   /desktop|imac|mac-?pro|pc|workstation|tower/i,
            watch:     /apple-?watch|galaxy-?watch|fitbit|garmin|amazfit|wear-?os/i,
            wearable:  /band|mi-?band|whoop|oura|smart-?ring/i,
            ebook:     /kindle|kobo|nook|e-?reader|boox/i,
            ipod:      /ipod/i,
            tv:        /tv|roku|firestick|chromecast|appletv|shield|smart-?tv|bravia|samsung-tv|lg-?tv|vizio|tivo|fire-?tv/i,
            audio:     /sonos|bose|homepod-?mini|echo-?dot|echo-?show|speaker|receiver|soundbar|denon|marantz|yamaha-rx/i,
            gaming:    /xbox|playstation|ps[345]|switch|steam-?deck|nvidia-?shield|oculus|quest|vr/i,
            camera:    /camera|gopro|ring|nest-?cam|wyze|arlo|blink|eufy|reolink|hikvision|dahua|ip-?cam|ipcam/i,
            voip:      /voip|polycom|cisco-?phone|yealink|grandstream|sip-?phone|ip-?phone/i,
            printer:   /printer|hp-|epson|canon|brother|laserjet|officejet|deskjet|pixma/i,
            scanner:   /scanner|scan|fujitsu-?scan|epson-?scan/i,
            projector: /projector|benq|optoma|epson-?proj|viewsonic/i,
            pos:       /pos|terminal|verifone|ingenico|square|clover|register/i,
            network:   /router|switch|ap|access-?point|unifi|ubiquiti|mikrotik|netgear|linksys|asus-?rt|tp-?link|eap|eero|orbi/i,
            server:    /server|nas|synology|qnap|truenas|proxmox|pve|esxi|vmware|hyperv/i,
            iot:       /echo|alexa|google-?home|hub|sensor|thermostat|nest-?hub|smart-?plug|smart-?switch|tuya|tasmota|shelly|hue|lifx|wemo/i
        };
        for (var type in patterns) {
            if (patterns[type].test(hostname)) return type;
        }
        return 'unknown';
    }

    // Get device icon based on type (matches Peplink categories)
    function getDeviceIcon(type) {
        var icons = {
            phone: '\uD83D\uDCF1',         // 📱 Smartphone
            tablet: '\uD83D\uDCF1',        // 📱 Tablet (similar to phone)
            laptop: '\uD83D\uDCBB',        // 💻 Laptop
            desktop: '\uD83D\uDDA5\uFE0F', // 🖥️ Desktop
            watch: '\u231A',               // ⌚ Smart Watch
            wearable: '\u231A',            // ⌚ Wearable
            ebook: '\uD83D\uDCD6',         // 📖 eBook Reader
            ipod: '\uD83C\uDFB5',          // 🎵 iPod
            tv: '\uD83D\uDCFA',            // 📺 TV / Audio & Video
            audio: '\uD83D\uDD0A',         // 🔊 Audio & Video
            gaming: '\uD83C\uDFAE',        // 🎮 Game Console
            camera: '\uD83D\uDCF7',        // 📷 Photo Camera / IP Camera
            voip: '\u260E\uFE0F',          // ☎️ VoIP
            printer: '\uD83D\uDDA8\uFE0F', // 🖨️ Printer
            scanner: '\uD83D\uDCE0',       // 📠 Scanner
            projector: '\uD83D\uDCFD\uFE0F', // 📽️ Projector
            pos: '\uD83D\uDCB3',           // 💳 Point of Sale
            network: '\uD83C\uDF10',       // 🌐 Network Appliance
            server: '\uD83D\uDCBE',        // 💾 Server
            iot: '\uD83D\uDD0C',           // 🔌 IoT
            unknown: '\u2753'              // ❓ Unclassified
        };
        return icons[type] || icons.unknown;
    }

    // Format lease expiry time
    function formatExpiry(expiryTimestamp) {
        if (!expiryTimestamp) return 'Unknown';
        var now = Math.floor(Date.now() / 1000);
        var remaining = expiryTimestamp - now;
        if (remaining <= 0) return 'Expired';
        var days = Math.floor(remaining / 86400);
        var hours = Math.floor((remaining % 86400) / 3600);
        var mins = Math.floor((remaining % 3600) / 60);
        if (days > 0) return 'Expires in ' + days + ' day' + (days > 1 ? 's' : '');
        if (hours > 0) return 'Expires in ' + hours + ' hour' + (hours > 1 ? 's' : '');
        return 'Expires in ' + mins + ' min' + (mins > 1 ? 's' : '');
    }

    // Load client metadata from server
    function loadClientMeta() {
        return api('get_client_meta').then(function(data) {
            clientMeta = data || {};
        }).catch(function() { clientMeta = {}; });
    }

    // Load DHCP reservations from server
    function loadReservations() {
        return api('get_reservations').then(function(data) {
            reservedMacs = data || {};
        }).catch(function() { reservedMacs = {}; });
    }

    // Save client metadata
    function saveClientMeta(mac, alias, type) {
        var params = { mac: mac };
        if (alias !== undefined && alias !== null) params.alias = alias;
        if (type !== undefined && type !== null) params.type = type;
        return api('set_client_meta', params).then(function(resp) {
            if (resp && resp.success) {
                if (!clientMeta[mac.toLowerCase()]) clientMeta[mac.toLowerCase()] = {};
                if (alias) clientMeta[mac.toLowerCase()].alias = alias;
                if (type) clientMeta[mac.toLowerCase()].type = type;
            }
            return resp;
        });
    }

    // DHCP Reservation popup (saves to pending, not immediately)
    function showReservationPopup(mac, ip, name) {
        var macLower = mac.toLowerCase();
        var existing = reservedMacs[macLower];
        var pending = pendingReservations[macLower];
        // If there's a pending change, show that instead
        if (pending && pending.action !== 'remove') {
            existing = { ip: pending.ip, name: pending.name };
        }

        var popup = document.createElement('div');
        popup.className = 'jm-popup-overlay';
        popup.innerHTML =
            '<div class="jm-popup">' +
            '<h3>' + (existing ? _('Edit DHCP Reservation') : _('Add DHCP Reservation')) + '</h3>' +
            '<div class="jm-popup-row"><label>' + _('MAC Address') + '</label><input type="text" id="res-mac" value="' + escapeHtml(mac) + '" readonly></div>' +
            '<div class="jm-popup-row"><label>' + _('IP Address') + '</label><input type="text" id="res-ip" value="' + escapeHtml(existing ? existing.ip : ip) + '"></div>' +
            '<div class="jm-popup-row"><label>' + _('Name') + '</label><input type="text" id="res-name" value="' + escapeHtml(existing ? existing.name : name) + '"></div>' +
            '<div class="jm-popup-buttons">' +
            (existing || pending ? '<button class="btn-danger" id="res-delete">' + _('Remove') + '</button>' : '') +
            '<button class="btn-secondary" id="res-cancel">' + _('Cancel') + '</button>' +
            '<button class="btn-primary" id="res-save">' + _('Save') + '</button>' +
            '</div></div>';
        document.body.appendChild(popup);

        // Cancel
        popup.querySelector('#res-cancel').onclick = function() { popup.remove(); };
        popup.onclick = function(e) { if (e.target === popup) popup.remove(); };

        // Save to pending (not immediately to backend)
        popup.querySelector('#res-save').onclick = function() {
            var newIp = popup.querySelector('#res-ip').value.trim();
            var newName = popup.querySelector('#res-name').value.trim();
            if (!newIp) { alert(_('IP address is required')); return; }

            pendingReservations[macLower] = {
                ip: newIp,
                name: newName,
                action: reservedMacs[macLower] ? 'update' : 'add'
            };
            popup.remove();
            updatePendingUI();
            updateClients();  // Re-render to show pending state
        };

        // Delete (mark as pending remove)
        var delBtn = popup.querySelector('#res-delete');
        if (delBtn) {
            delBtn.onclick = function() {
                if (!confirm('Remove DHCP reservation for ' + mac + '?\n(Click "Save and Apply" to finalize)')) return;
                if (reservedMacs[macLower]) {
                    // Existing reservation - mark for removal
                    pendingReservations[macLower] = { action: 'remove' };
                } else {
                    // Was only pending add - just remove from pending
                    delete pendingReservations[macLower];
                }
                popup.remove();
                updatePendingUI();
                updateClients();
            };
        }
    }

    // Update pending changes UI (button states, indicator)
    function updatePendingUI() {
        var hasPending = Object.keys(pendingMeta).length > 0 || Object.keys(pendingReservations).length > 0;
        var indicator = document.getElementById('client-pending-indicator');
        var saveBtn = document.getElementById('client-save-btn');
        var resetBtn = document.getElementById('client-reset-btn');

        if (indicator) indicator.style.display = hasPending ? 'inline' : 'none';
        if (saveBtn) saveBtn.disabled = !hasPending;
        if (resetBtn) {
            resetBtn.disabled = !hasPending;
            resetBtn.style.borderColor = hasPending ? '#e74c3c' : '#95a5a6';
            resetBtn.style.color = hasPending ? '#e74c3c' : '#95a5a6';
        }
    }

    // Check if a MAC has pending changes
    function hasPendingChange(mac) {
        var macLower = mac.toLowerCase();
        return pendingMeta[macLower] || pendingReservations[macLower];
    }

    // Get effective reservation (considering pending)
    function getEffectiveReservation(mac) {
        var macLower = mac.toLowerCase();
        var pending = pendingReservations[macLower];
        if (pending) {
            if (pending.action === 'remove') return null;
            return { ip: pending.ip, name: pending.name, pending: true };
        }
        return reservedMacs[macLower];
    }

    // Save all pending changes to backend
    function saveClientChanges() {
        var saveBtn = document.getElementById('client-save-btn');
        if (saveBtn) {
            saveBtn.disabled = true;
            saveBtn.textContent = _('Saving...');
        }

        var promises = [];

        // Save pending meta changes (names, types)
        Object.keys(pendingMeta).forEach(function(mac) {
            var meta = pendingMeta[mac];
            promises.push(saveClientMeta(mac, meta.alias, meta.type));
        });

        // Save pending reservations
        Object.keys(pendingReservations).forEach(function(mac) {
            var res = pendingReservations[mac];
            if (res.action === 'remove') {
                promises.push(api('delete_reservation', { mac: mac }));
            } else {
                promises.push(api('set_reservation', { mac: mac, ip: res.ip, name: res.name }));
            }
        });

        Promise.all(promises).then(function(results) {
            var failed = results.filter(function(r) { return r && r.error; });
            if (failed.length > 0) {
                alert('Some changes failed to save:\n' + failed.map(function(f) { return f.error; }).join('\n'));
            }
            // Clear pending state
            pendingMeta = {};
            pendingReservations = {};
            // Reload data from backend
            return Promise.all([loadClientMeta(), loadReservations()]);
        }).then(function() {
            updatePendingUI();
            updateClients();
            if (saveBtn) {
                saveBtn.textContent = _('Save and Apply');
            }
        }).catch(function(err) {
            alert('Failed to save changes: ' + err);
            if (saveBtn) {
                saveBtn.disabled = false;
                saveBtn.textContent = _('Save and Apply');
            }
        });
    }

    // Reset all pending changes (discard without saving)
    function resetClientChanges() {
        if (!confirm('Discard all unsaved changes?')) return;
        pendingMeta = {};
        pendingReservations = {};
        // Remove any editing state so updateClients doesn't skip refresh
        var editingCell = document.querySelector('.client-name.editing');
        if (editingCell) {
            editingCell.classList.remove('editing');
            var row = editingCell.closest('tr');
            if (row) row.classList.remove('row-editing');
        }
        updatePendingUI();
        updateClients();
    }

    // ============================================================
    // Client List Sorting & Grouping Helpers
    // ============================================================

    function getSubnetGroup(ip) {
        if (!ip || ip === '--') return 'unknown';
        // Tailscale IPs start with 100.
        if (ip.startsWith('100.')) return 'tailscale';
        var parts = ip.split('.');
        if (parts.length >= 3) return parts[0] + '.' + parts[1] + '.' + parts[2];
        return 'unknown';
    }

    function getSubnetLabel(group) {
        if (group === 'tailscale') return 'Tailscale (100.x.x.x)';
        if (group === 'unknown') return 'Unknown';
        return group + '.x';
    }

    function isGroupCollapsedByDefault(group) {
        // Local LAN subnets (192.168.x, 10.201.x matching router) expanded
        if (group.startsWith('192.168.')) return false;
        if (group.startsWith('10.201.')) return false;
        // Tailscale expanded
        if (group === 'tailscale') return false;
        // Upstream/other subnets collapsed by default
        return true;
    }

    function getGroupSortOrder(group) {
        // Sort order: local LAN first, then Tailscale, then others alphabetically
        if (group.startsWith('192.168.')) return '0_' + group;
        if (group.startsWith('10.201.')) return '1_' + group;
        if (group === 'tailscale') return '2_tailscale';
        return '3_' + group;
    }

    function ipToNumberClient(ip) {
        if (!ip || ip === '--') return 0;
        var parts = ip.split('.');
        if (parts.length !== 4) return 0;
        return ((parseInt(parts[0], 10) << 24) +
                (parseInt(parts[1], 10) << 16) +
                (parseInt(parts[2], 10) << 8) +
                parseInt(parts[3], 10)) >>> 0;
    }

    function sortClientsList(clients, col, dir) {
        return clients.slice().sort(function(a, b) {
            var valA, valB;
            if (col === 'ip') {
                valA = ipToNumberClient(a.ip);
                valB = ipToNumberClient(b.ip);
            } else if (col === 'download' || col === 'upload') {
                valA = a[col] || 0;
                valB = b[col] || 0;
            } else {
                valA = (a[col] || '').toString().toLowerCase();
                valB = (b[col] || '').toString().toLowerCase();
            }
            if (valA === valB) return 0;
            return dir === 'asc' ? (valA > valB ? 1 : -1) : (valA < valB ? 1 : -1);
        });
    }

    function renderClientHeaders() {
        var columns = [
            { key: 'ip', label: _('IP Address'), width: '115px', sortable: true },
            { key: 'type', label: _('Type'), width: '40px', sortable: false },
            { key: 'name', label: _('Name'), width: '', sortable: true },
            { key: 'download', label: _('Download'), width: '', sortable: true },
            { key: 'upload', label: _('Upload'), width: '', sortable: true },
            { key: 'source', label: _('Source'), width: '70px', sortable: false },
            { key: 'mac', label: _('MAC Address'), width: '', sortable: true, colspan: 2 }
        ];
        var html = '<tr>';
        columns.forEach(function(col) {
            var style = col.width ? 'width:' + col.width + ';' : '';
            var colspanAttr = col.colspan ? ' colspan="' + col.colspan + '"' : '';
            if (col.key && col.sortable) {
                var isActive = clientSortColumn === col.key;
                // Always show arrow placeholder to prevent column shifting, hide with visibility when inactive
                var arrowStyle = isActive ? '' : 'visibility:hidden;';
                var arrowClass = isActive ? (clientSortDirection === 'asc' ? 'sort-asc' : 'sort-desc') : 'sort-asc';
                var arrow = '<span class="sort-icon ' + arrowClass + '" style="' + arrowStyle + '"></span>';
                html += '<th class="sortable" data-sort="' + col.key + '"' + colspanAttr + ' style="' + style + 'white-space:nowrap;">' + col.label + arrow + '</th>';
            } else {
                html += '<th' + colspanAttr + ' style="' + style + '">' + (col.label || '') + '</th>';
            }
        });
        return html + '</tr>';
    }

    function renderGroupHeader(group, count, isCollapsed) {
        var arrowClass = isCollapsed ? 'client-group-arrow collapsed' : 'client-group-arrow';
        return '<tr class="client-group-header" data-group="' + group + '">' +
            '<td colspan="8">' +
            '<span class="' + arrowClass + '">▼</span>' +
            getSubnetLabel(group) +
            '<span class="client-group-count">(' + count + ' device' + (count !== 1 ? 's' : '') + ')</span>' +
            '</td></tr>';
    }

    function renderClientsTable() {
        if (!clientsDataCache) return;

        var tbody = document.getElementById('clients-tbody');
        var thead = document.querySelector('#clients-table thead');
        if (!tbody || !thead) return;

        // Render sortable headers
        thead.innerHTML = renderClientHeaders();

        // Group clients by subnet
        var groups = {};
        clientsDataCache.forEach(function(client) {
            var group = getSubnetGroup(client.ip);
            if (!groups[group]) groups[group] = [];
            groups[group].push(client);
        });

        // Sort group keys
        var sortedGroupKeys = Object.keys(groups).sort(function(a, b) {
            return getGroupSortOrder(a).localeCompare(getGroupSortOrder(b));
        });

        // Initialize collapsed state for new groups
        sortedGroupKeys.forEach(function(group) {
            if (collapsedGroups[group] === undefined) {
                collapsedGroups[group] = isGroupCollapsedByDefault(group);
            }
        });

        var rows = '';
        sortedGroupKeys.forEach(function(group) {
            var groupClients = groups[group];
            var isCollapsed = collapsedGroups[group];

            // Render group header
            rows += renderGroupHeader(group, groupClients.length, isCollapsed);

            // Sort clients within group
            var sorted = sortClientsList(groupClients, clientSortColumn, clientSortDirection);

            // Render client rows
            sorted.forEach(function(c) {
                var hiddenClass = isCollapsed ? ' hidden' : '';
                rows += renderClientRow(c, group, hiddenClass);
            });
        });

        tbody.innerHTML = rows || '<tr><td colspan="8" style="text-align:center;color:#999;">No clients found</td></tr>';

        // Attach click handlers
        attachClientTableHandlers();
    }

    function renderClientRow(c, group, hiddenClass) {
        var macLower = c.mac ? c.mac.toLowerCase() : '';
        var metaPending = pendingMeta[macLower];
        var meta = clientMeta[macLower] || {};
        var savedName = (metaPending && metaPending.alias) || meta.alias || c.hostname;
        var isUnnamed = !savedName || savedName === '*';
        var displayName = isUnnamed ? '' : savedName;
        var deviceType = (metaPending && metaPending.type) || meta.type || detectDeviceType(c.hostname);
        var icon = getDeviceIcon(deviceType);

        var effectiveRes = c.mac ? getEffectiveReservation(c.mac) : null;
        var hasPendingRes = pendingReservations[macLower];
        var ipTitle = effectiveRes ? 'Static reservation' : formatExpiry(c.expiry);

        var tagIcon = '';
        if (c.source === 'LAN') {
            if (hasPendingRes) {
                if (hasPendingRes.action === 'remove') {
                    tagIcon = '<span style="color:#e74c3c;" title="Pending removal">\uD83C\uDFF7\uFE0F</span>';
                } else {
                    tagIcon = '<span style="color:#f39c12;" title="Pending save">\uD83C\uDFF7\uFE0F</span>';
                }
            } else if (effectiveRes) {
                tagIcon = '<span style="color:#27ae60;" title="DHCP Reserved">\uD83C\uDFF7\uFE0F</span>';
            } else {
                tagIcon = '<span style="color:#bdc3c7;" title="Add to DHCP reservation">\uD83C\uDFF7\uFE0F</span>';
            }
        }

        var rowStyle = '';
        if (hasPendingRes && hasPendingRes.action !== 'remove') {
            rowStyle = 'background:#fff8e1;';
        } else if (effectiveRes && !hasPendingRes) {
            rowStyle = 'background:#f0fff4;';
        } else if (c.source === 'Tailscale') {
            rowStyle = 'background:#f0f9ff;';
        }

        var nameClass = 'client-name';
        if (metaPending) nameClass += ' client-pending-name';
        var nameDisplay = isUnnamed ? '<span class="name-placeholder">' + _('Tap to name') + '</span>' : escapeHtml(displayName);

        var nameCell = '';
        if (c.source === 'LAN') {
            nameCell = '<span class="name-display">' + nameDisplay + '</span>' +
                '<div class="name-edit">' +
                '<input type="text" value="' + escapeHtml(displayName) + '" data-original="' + escapeHtml(displayName) + '" placeholder="' + _('Enter name...') + '">' +
                '</div>' +
                '<div class="name-edit-buttons">' +
                '<button class="btn-save">' + _('Save') + '</button>' +
                '<button class="btn-cancel">' + _('Cancel') + '</button>' +
                '</div>';
        } else {
            nameCell = escapeHtml(c.name || c.hostname || '--');
        }

        var offlineClass = c.offline ? ' client-offline' : '';
        var sourceDisplay = c.source === 'Tailscale' ? '<span style="color:#3498db;">Tailscale</span>' : c.source;
        var macDisplay = c.source === 'Tailscale' ? (c.os || '--') : (c.mac || '--');

        var row = '<tr class="client-row' + hiddenClass + offlineClass + '" data-group="' + group + '" style="' + rowStyle + '">';
        row += '<td class="client-ip-cell" data-expiry="' + (c.expiry || '') + '">' + escapeHtml(c.ip) + '</td>';
        row += '<td style="text-align:center;">' + icon + '</td>';
        if (c.source === 'LAN') {
            row += '<td class="' + nameClass + '" data-mac="' + escapeHtml(c.mac) + '">' + nameCell + '</td>';
        } else {
            row += '<td>' + nameCell + '</td>';
        }
        row += '<td>' + (c.download > 0 ? formatBytesCompact(c.download) : '--') + '</td>';
        row += '<td>' + (c.upload > 0 ? formatBytesCompact(c.upload) : '--') + '</td>';
        row += '<td>' + sourceDisplay + '</td>';
        row += '<td style="font-family:monospace;font-size:11px;color:#7f8c8d;">' + escapeHtml(macDisplay) + '</td>';
        if (c.source === 'LAN') {
            row += '<td class="reservation-tag" data-mac="' + escapeHtml(c.mac) + '" data-ip="' + escapeHtml(c.ip) + '" data-name="' + escapeHtml(displayName) + '">' + tagIcon + '</td>';
        } else {
            row += '<td></td>';
        }
        row += '</tr>';
        return row;
    }

    function attachClientTableHandlers() {
        var table = document.getElementById('clients-table');
        if (!table) return;

        // Sort column click handlers
        table.querySelectorAll('th.sortable').forEach(function(th) {
            th.onclick = function() {
                var col = th.dataset.sort;
                if (clientSortColumn === col) {
                    clientSortDirection = clientSortDirection === 'asc' ? 'desc' : 'asc';
                } else {
                    clientSortColumn = col;
                    // Default direction: asc for text/IP, desc for numeric
                    clientSortDirection = (col === 'download' || col === 'upload') ? 'desc' : 'asc';
                }
                renderClientsTable();
            };
        });

        // Group header collapse/expand handlers
        table.querySelectorAll('.client-group-header').forEach(function(header) {
            header.onclick = function() {
                var group = header.dataset.group;
                collapsedGroups[group] = !collapsedGroups[group];
                renderClientsTable();
            };
        });

        // IP cell hover for lease expiry tooltip
        table.addEventListener('mousemove', function(e) {
            var cell = e.target.closest('.client-ip-cell');
            if (cell && cell.dataset.expiry) {
                var expiryText = formatExpiry(parseInt(cell.dataset.expiry, 10));
                showChartTooltip(e.clientX, e.clientY, expiryText);
            }
        });

        table.addEventListener('mouseout', function(e) {
            if (e.target.classList.contains('client-ip-cell')) {
                hideChartTooltip();
            }
        });
    }

    function updateClients() {
        var tbody = document.getElementById('clients-tbody');
        // Skip refresh if user is actively editing a name
        if (tbody && tbody.querySelector('.client-name.editing')) {
            return;
        }
        api('clients').then(function(data) {
            if (!data) {
                console.error('updateClients: No data from clients API');
                tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;color:#999;">Failed to load clients</td></tr>';
                return;
            }
            var results = [
                data.dhcp_leases || '',
                data.arp || '',
                data.conntrack || ''
            ];
            var leases = {};
            var traffic = {};

            // Parse conntrack for traffic per IP
            results[2].split('\n').forEach(function(line) {
                if (!line.trim()) return;
                var srcMatch = line.match(/src=(\d+\.\d+\.\d+\.\d+)/);
                var bytesMatches = line.match(/bytes=(\d+)/g);
                if (srcMatch && bytesMatches) {
                    var ip = srcMatch[1];
                    if (!traffic[ip]) traffic[ip] = { rx: 0, tx: 0 };
                    if (bytesMatches[0]) traffic[ip].tx += parseInt(bytesMatches[0].replace('bytes=', ''), 10);
                    if (bytesMatches[1]) traffic[ip].rx += parseInt(bytesMatches[1].replace('bytes=', ''), 10);
                }
            });

            // Parse DHCP leases with expiry times
            results[0].trim().split('\n').forEach(function(line) {
                if (!line.trim()) return;
                var p = line.split(/\s+/);
                if (p.length >= 4) {
                    var expiry = parseInt(p[0], 10);
                    leases[p[2]] = { mac: p[1], hostname: p[3] || '*', ip: p[2], expiry: expiry };
                }
            });

            // Parse ARP for additional entries
            results[1].trim().split('\n').forEach(function(line) {
                if (line.indexOf('IP address') >= 0) return;
                var p = line.split(/\s+/);
                if (p.length >= 4 && p[0].match(/^\d+\./)) {
                    if (!leases[p[0]]) leases[p[0]] = { mac: p[3], hostname: '*', ip: p[0], expiry: null };
                }
            });

            // Build unified clients array for caching
            var clients = [];

            // LAN clients
            Object.keys(leases).forEach(function(ip) {
                var c = leases[ip];
                var t = traffic[ip] || { rx: 0, tx: 0 };
                var macLower = c.mac ? c.mac.toLowerCase() : '';
                var metaPending = pendingMeta[macLower];
                var meta = clientMeta[macLower] || {};
                var savedName = (metaPending && metaPending.alias) || meta.alias || c.hostname;
                var deviceType = (metaPending && metaPending.type) || meta.type || detectDeviceType(c.hostname);

                clients.push({
                    ip: ip,
                    mac: c.mac,
                    hostname: c.hostname,
                    name: savedName,
                    type: deviceType,
                    download: t.rx,
                    upload: t.tx,
                    source: 'LAN',
                    expiry: c.expiry,
                    offline: false,
                    os: null
                });
            });

            // Tailscale peers
            if (data.tailscale) {
                try {
                    var ts = typeof data.tailscale === 'string' ? JSON.parse(data.tailscale) : data.tailscale;
                    if (ts.Peer) {
                        Object.keys(ts.Peer).forEach(function(key) {
                            var peer = ts.Peer[key];
                            var hostname = peer.HostName || peer.DNSName || 'Unknown';
                            var ip = peer.TailscaleIPs && peer.TailscaleIPs[0] ? peer.TailscaleIPs[0] : '--';
                            var deviceType = detectDeviceType(hostname);

                            clients.push({
                                ip: ip,
                                mac: null,
                                hostname: hostname,
                                name: hostname,
                                type: deviceType,
                                download: 0,
                                upload: 0,
                                source: 'Tailscale',
                                expiry: null,
                                offline: !peer.Online,
                                os: peer.OS || '--'
                            });
                        });
                    }
                } catch (e) {
                    console.error('Failed to parse Tailscale status:', e);
                }
            }

            // Cache the data and render
            clientsDataCache = clients;
            renderClientsTable();
        });
    }

    // ============================================================
    // WiFi APs Tab
    // ============================================================
    var prevSurveyData = {}; // Track previous survey values for delta calculation

    function updateWifiAps() {
        fetch(window.location.pathname + '/wifi_status')
            .then(function(r) { return r.json(); })
            .then(function(data) {
                // Calculate real-time utilization from survey deltas
                data.local_radios.forEach(function(radio) {
                    if (radio.survey_active !== undefined && radio.survey_busy !== undefined) {
                        var prev = prevSurveyData[radio.name];
                        if (prev && radio.survey_active > prev.active) {
                            var deltaActive = radio.survey_active - prev.active;
                            var deltaBusy = radio.survey_busy - prev.busy;
                            if (deltaActive > 0) {
                                radio.utilization = Math.round((deltaBusy / deltaActive) * 100);
                            }
                        }
                        // Store current values for next calculation
                        prevSurveyData[radio.name] = {
                            active: radio.survey_active,
                            busy: radio.survey_busy
                        };
                    }
                });

                // Update health tiles
                document.getElementById('wifi-aps-online').textContent = data.totals.aps_online + '/' + data.totals.aps_total;
                document.getElementById('wifi-total-clients').textContent = data.totals.total_clients;
                document.getElementById('wifi-local-radios').textContent = data.local_radios.length;

                // Find worst AP (down radios, or highest utilization)
                var worstApEl = document.getElementById('wifi-worst-ap');
                var downRadios = data.local_radios.filter(function(r) { return !r.up; });
                if (downRadios.length > 0) {
                    worstApEl.textContent = downRadios[0].name;
                    worstApEl.style.color = '#e74c3c';
                } else {
                    // Check if any radio has utilization data yet
                    var hasAnyUtilization = data.local_radios.some(function(r) { return r.utilization !== undefined; });
                    if (!hasAnyUtilization) {
                        worstApEl.innerHTML = '<span class="tile-spinner"></span>';
                    } else {
                        // Find radio with highest utilization
                        var sorted = data.local_radios.slice().sort(function(a, b) {
                            return (b.utilization || 0) - (a.utilization || 0);
                        });
                        if (sorted[0] && sorted[0].utilization > 50) {
                            worstApEl.textContent = sorted[0].name + ' (' + sorted[0].utilization + '%)';
                            worstApEl.style.color = sorted[0].utilization > 70 ? '#e74c3c' : '#f39c12';
                        } else {
                            worstApEl.textContent = _('All Good');
                            worstApEl.style.color = '#27ae60';
                        }
                    }
                }

                // Render local radios with utilization bars
                var localGrid = document.getElementById('wifi-local-grid');
                if (data.local_radios.length === 0) {
                    localGrid.innerHTML = '<p style="color:#999;margin:10px 0;">' + _('No local Wi-Fi radios detected') + '</p>';
                } else {
                    var html = '';
                    data.local_radios.forEach(function(radio) {
                        var indicatorClass = radio.up ? 'green' : 'red';
                        var stateText = radio.up ? _('UP') : _('DOWN');
                        var hasUtilization = radio.utilization !== undefined;
                        var utilization = radio.utilization || 0;
                        var utilizationText = hasUtilization ? utilization + '%' : '<span class="tile-spinner" style="width:12px;height:12px;"></span>';
                        var utilizationColor = utilization > 70 ? '#e74c3c' : (utilization > 40 ? '#f39c12' : '#27ae60');
                        html += '<div class="jm-block-compact">';
                        html += '<div class="jm-block-header" style="margin-bottom:4px;padding-bottom:4px;">';
                        html += '<span class="jm-indicator ' + indicatorClass + '" style="width:8px;height:8px;"></span>';
                        html += '<span class="jm-block-title" style="font-size:12px;">' + escapeHtml(radio.name) + '</span>';
                        if (radio.band) {
                            html += '<span style="margin-left:auto;font-size:10px;color:#7f8c8d;">' + escapeHtml(radio.band) + '</span>';
                        }
                        html += '</div>';
                        html += '<div class="jm-big-value">' + stateText + '</div>';
                        html += '<div class="jm-row"><span class="jm-label">' + _('Channel') + '</span><span class="jm-value">' + escapeHtml(radio.channel) + '</span></div>';
                        html += '<div class="jm-row"><span class="jm-label">' + _('Tx Power') + '</span><span class="jm-value">' + escapeHtml(radio.txpower) + '</span></div>';
                        html += '<div class="jm-row"><span class="jm-label">' + _('Clients') + '</span><span class="jm-value">' + radio.clients + '</span></div>';
                        // Utilization bar
                        html += '<div class="jm-row" style="flex-direction:column;gap:2px;">';
                        html += '<span class="jm-label" style="width:100%;">' + _('Utilization') + ' ' + utilizationText + '</span>';
                        html += '<div style="width:100%;height:6px;background:#ecf0f1;border-radius:3px;overflow:hidden;">';
                        html += '<div style="width:' + utilization + '%;height:100%;background:' + utilizationColor + ';"></div>';
                        html += '</div></div>';
                        html += '</div>';
                    });
                    localGrid.innerHTML = html;
                }

                // Render connected clients table
                var clientsTbody = document.getElementById('wifi-clients-tbody');
                if (clientsTbody) {
                    var allClients = [];
                    data.local_radios.forEach(function(radio) {
                        if (radio.client_list) {
                            radio.client_list.forEach(function(client) {
                                allClients.push(client);
                            });
                        }
                    });
                    if (allClients.length === 0) {
                        clientsTbody.innerHTML = '<tr><td colspan="6" style="text-align:center;color:#999;">' + _('No clients connected') + '</td></tr>';
                    } else {
                        var rows = '';
                        allClients.forEach(function(client) {
                            var signalClass = client.signal > -50 ? 'color:#27ae60;' : (client.signal > -70 ? 'color:#f39c12;' : 'color:#e74c3c;');
                            var deviceName = client.hostname || client.mac;
                            rows += '<tr>';
                            rows += '<td>' + escapeHtml(deviceName) + '</td>';
                            rows += '<td style="font-family:monospace;font-size:11px;">' + escapeHtml(client.mac) + '</td>';
                            rows += '<td style="' + signalClass + '">' + client.signal + ' dBm</td>';
                            rows += '<td>' + formatBytesCompact(client.rx_bytes || 0) + '</td>';
                            rows += '<td>' + formatBytesCompact(client.tx_bytes || 0) + '</td>';
                            var bandInfo = client.band || 'N/A';
                            if (client.wifi_gen) bandInfo += ' (' + client.wifi_gen + ')';
                            rows += '<td>' + escapeHtml(bandInfo) + '</td>';
                            rows += '</tr>';
                        });
                        clientsTbody.innerHTML = rows;
                    }
                }
            })
            .catch(function(e) {
                console.error('Failed to fetch WiFi status:', e);
                document.getElementById('wifi-local-grid').innerHTML = '<p style="color:#e74c3c;margin:10px 0;">Failed to load WiFi status</p>';
            });

        // Also update remote APs if configured
        updateRemoteAps();
    }

    // ============================================================
    // Remote APs
    // ============================================================
    var remoteApsExpanded = false;

    function getRemoteApList() {
        try {
            return JSON.parse(localStorage.getItem('jammonitor_remote_aps') || '[]');
        } catch(e) { return []; }
    }

    function saveRemoteApList(list) {
        localStorage.setItem('jammonitor_remote_aps', JSON.stringify(list));
    }

    function toggleRemoteAps() {
        remoteApsExpanded = !remoteApsExpanded;
        var content = document.getElementById('remote-aps-content');
        var header = document.querySelector('.jm-collapsible-header span');
        var collapsible = document.querySelector('.jm-collapsible');
        if (remoteApsExpanded) {
            content.style.display = 'block';
            header.textContent = '▼ ' + _('Remote APs');
            collapsible.classList.add('expanded');
            updateRemoteAps();
        } else {
            content.style.display = 'none';
            header.textContent = '▶ ' + _('Remote APs');
            collapsible.classList.remove('expanded');
        }
    }

    function editApList() {
        var list = getRemoteApList();
        document.getElementById('ap-list-editor').value = JSON.stringify(list, null, 2);
        document.getElementById('remote-ap-editor').style.display = 'block';
        document.getElementById('edit-ap-btn').style.display = 'none';
    }

    function cancelApEdit() {
        document.getElementById('remote-ap-editor').style.display = 'none';
        document.getElementById('edit-ap-btn').style.display = 'block';
    }

    function saveApList() {
        var text = document.getElementById('ap-list-editor').value.trim();
        try {
            var list = text ? JSON.parse(text) : [];
            if (!Array.isArray(list)) throw new Error('Must be array');
            // Validate entries
            list = list.filter(function(ap) {
                return ap && ap.name && ap.ip && /^\d+\.\d+\.\d+\.\d+$/.test(ap.ip);
            });
            saveRemoteApList(list);
            cancelApEdit();
            updateRemoteAps();
        } catch(e) {
            alert('Invalid JSON format. Use: [{"name":"AP-1","ip":"10.0.0.2"}]');
        }
    }

    function updateRemoteAps() {
        var list = getRemoteApList();
        var countEl = document.getElementById('remote-ap-count');
        var listEl = document.getElementById('remote-ap-list');

        if (list.length === 0) {
            countEl.textContent = '';
            listEl.innerHTML = '<div style="padding:20px;background:#f8f9fa;border-radius:6px;text-align:center;"><p style="color:#95a5a6;margin:0;">' + _('No remote APs configured') + '</p><p style="color:#bdc3c7;font-size:11px;margin:5px 0 0;">' + _('Click "+ Add APs" below to monitor external access points') + '</p></div>';
            return;
        }

        countEl.textContent = '(' + list.length + ' configured)';

        // Ping each AP
        var ips = list.map(function(ap) { return ap.ip; }).join(',');
        fetch(window.location.pathname + '/wifi_status?remote_ips=' + encodeURIComponent(ips))
            .then(function(r) { return r.json(); })
            .then(function(data) {
                var remoteData = {};
                (data.remote_aps || []).forEach(function(ap) {
                    remoteData[ap.ip] = ap;
                });

                var html = '';
                list.forEach(function(ap) {
                    var status = remoteData[ap.ip];
                    var online = status && status.online;
                    var latency = status && status.latency ? status.latency.toFixed(1) + ' ms' : '--';
                    html += '<div class="jm-remote-ap-item">';
                    html += '<span class="jm-remote-ap-status ' + (online ? 'online' : 'offline') + '"></span>';
                    html += '<span style="flex:1;font-size:12px;">' + escapeHtml(ap.name) + '</span>';
                    html += '<span style="font-size:11px;color:#7f8c8d;margin-right:15px;">' + escapeHtml(ap.ip) + '</span>';
                    html += '<span style="font-size:11px;color:' + (online ? '#27ae60' : '#e74c3c') + ';">' + latency + '</span>';
                    html += '</div>';
                });
                listEl.innerHTML = html;
            })
            .catch(function(e) {
                console.error('Failed to ping remote APs:', e);
            });
    }

    // ============================================================
    // WAN Policy Tab - Category-based drag-and-drop
    // ============================================================
    var wanDragInProgress = false;
    var wanPendingChanges = {}; // Track interfaces with pending backend changes

    function loadWanPolicy(skipRender) {
        // Don't reload while drag is in progress
        if (wanDragInProgress) return;

        // Load bypass status first (or in parallel)
        loadBypassStatus();

        if (!skipRender) {
            // Clear all dropzones while loading
            document.querySelectorAll('.wan-category-dropzone').forEach(function(zone) {
                zone.innerHTML = '<p style="color:#999;text-align:center;padding:10px;">Loading...</p>';
            });
        }

        fetch(window.location.pathname + '/wan_policy')
            .then(function(r) { return r.json(); })
            .then(function(data) {
                wanPolicyData = data.interfaces || [];
                // Update modes from server, but preserve pending changes
                wanPolicyData.forEach(function(iface) {
                    // Only update from server if not pending
                    if (!wanPendingChanges[iface.name]) {
                        wanPolicyModes[iface.name] = iface.multipath || 'off';
                    } else {
                        // Check if server now matches our expected state
                        if (iface.multipath === wanPendingChanges[iface.name]) {
                            delete wanPendingChanges[iface.name];
                        }
                    }
                });
                renderWanPolicy();
            })
            .catch(function(e) {
                console.error('Failed to load WAN policy:', e);
                document.querySelectorAll('.wan-category-dropzone').forEach(function(zone) {
                    zone.innerHTML = '<p style="color:#e74c3c;text-align:center;padding:10px;">Failed to load</p>';
                });
            });
    }

    function startWanPolicyPolling() {
        // Poll every 5 seconds for 2 minutes after a change
        stopWanPolicyPolling();
        wanPolicyPollEnd = Date.now() + (2 * 60 * 1000); // 2 minutes
        wanPolicyPollTimer = setInterval(function() {
            if (Date.now() > wanPolicyPollEnd || currentView !== 'wan-policy') {
                stopWanPolicyPolling();
                return;
            }
            // Don't poll if drag in progress
            if (!wanDragInProgress) {
                loadWanPolicy(true); // silent refresh
            }
        }, 5000);
    }

    function stopWanPolicyPolling() {
        if (wanPolicyPollTimer) {
            clearInterval(wanPolicyPollTimer);
            wanPolicyPollTimer = null;
        }
    }

    // ============================================================
    // VPS Bypass Toggle
    // ============================================================

    function loadBypassStatus() {
        return fetch(window.location.pathname + '/bypass')
            .then(function(r) { return r.json(); })
            .then(function(data) {
                bypassEnabled = data.bypass_enabled || false;
                bypassActiveWan = data.active_wan || null;
                updateBypassUI();
                return data;
            })
            .catch(function(e) {
                console.error('Failed to load bypass status:', e);
            });
    }

    function updateBypassUI() {
        var banner = document.getElementById('bypass-banner');
        var checkbox = document.getElementById('bypass-checkbox');
        var icon = document.getElementById('bypass-icon');
        var title = document.getElementById('bypass-title');
        var desc = document.getElementById('bypass-desc');
        var hint = document.getElementById('wan-policy-hint');
        var container = document.getElementById('wan-policy-container');

        if (!banner) return;

        checkbox.checked = bypassEnabled;
        checkbox.disabled = bypassToggling;

        // Show switching state
        if (bypassToggling) {
            banner.classList.add('active');
            icon.innerHTML = '&#8987;'; // Hourglass
            title.textContent = _('Switching...');
            desc.textContent = _('Stopping/starting VPN services (~10 seconds)...');
            return;
        }

        if (bypassEnabled) {
            banner.classList.add('active');
            icon.innerHTML = '&#9888;'; // Warning sign
            title.textContent = _('VPS BYPASS ACTIVE');
            desc.textContent = _('VPS connection is OFF - traffic going direct via %s', bypassActiveWan || 'WAN');
            hint.style.display = 'none';
            container.classList.add('wan-policy-disabled');

            // Add overlay message if not already there
            if (!document.getElementById('bypass-disabled-msg')) {
                var overlay = document.createElement('div');
                overlay.id = 'bypass-disabled-msg';
                overlay.className = 'wan-policy-disabled-overlay';
                overlay.innerHTML = '<p>Turn off VPS Bypass to manage WAN priorities</p>';
                container.parentNode.insertBefore(overlay, container.nextSibling);
            }
        } else {
            banner.classList.remove('active');
            icon.innerHTML = '&#128274;'; // Lock icon
            title.textContent = _('VPS Bypass: OFF');
            desc.textContent = _('Traffic routed through VPS via MPTCP bonding');
            hint.style.display = 'block';
            container.classList.remove('wan-policy-disabled');

            // Remove overlay
            var overlay = document.getElementById('bypass-disabled-msg');
            if (overlay) overlay.remove();
        }
    }

    function toggleBypass() {
        if (bypassToggling) return;

        var newState = !bypassEnabled;
        var confirmMsg = newState
            ? _('Enable VPS Bypass?') + '\n\n' + _('This will:') + '\n• ' + _('Stop OpenVPN tunnel') + '\n• ' + _('Stop Shadowsocks proxy') + '\n• ' + _('Route traffic directly through your primary WAN') + '\n\n' + _('Connection will be interrupted for ~5 seconds.')
            : _('Disable VPS Bypass?') + '\n\n' + _('This will:') + '\n• ' + _('Restart OpenVPN tunnel') + '\n• ' + _('Restart Shadowsocks proxy') + '\n• ' + _('Route traffic through VPS again') + '\n\n' + _('Connection will be interrupted for ~10 seconds while VPN reconnects.');

        if (!confirm(confirmMsg)) {
            // Reset checkbox to current state
            document.getElementById('bypass-checkbox').checked = bypassEnabled;
            return;
        }

        bypassToggling = true;
        updateBypassUI();

        fetch(window.location.pathname + '/bypass', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ enable: newState })
        })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            bypassToggling = false;
            if (data.success) {
                bypassEnabled = data.bypass_enabled;
                bypassActiveWan = data.active_wan;
                updateBypassUI();
                // Reload WAN policy to reflect changes
                setTimeout(function() { loadWanPolicy(true); }, 2000);
            } else {
                alert('Failed to toggle bypass: ' + (data.error || 'Unknown error'));
                document.getElementById('bypass-checkbox').checked = bypassEnabled;
                updateBypassUI();
            }
        })
        .catch(function(e) {
            bypassToggling = false;
            console.error('Bypass toggle error:', e);
            alert('Failed to toggle bypass. Please try again.');
            document.getElementById('bypass-checkbox').checked = bypassEnabled;
            updateBypassUI();
        });
    }

    function renderWanPolicy() {
        // Clear all dropzones
        document.querySelectorAll('.wan-category-dropzone').forEach(function(zone) {
            zone.innerHTML = '';
        });

        // Close any open popup
        closeWanIpPopup();

        if (wanPolicyData.length === 0) {
            document.querySelector('.wan-category-dropzone[data-priority="off"]').innerHTML =
                '<p style="color:#999;text-align:center;padding:10px;">No WAN interfaces found</p>';
            return;
        }

        // Render each interface into its category
        wanPolicyData.forEach(function(iface, idx) {
            var mode = wanPolicyModes[iface.name] || 'off';
            var dropzone = document.querySelector('.wan-category-dropzone[data-priority="' + mode + '"]');
            if (!dropzone) {
                dropzone = document.querySelector('.wan-category-dropzone[data-priority="off"]');
            }

            // Determine status based on mode and connection
            var statusClass, statusText;
            if (mode === 'off') {
                statusClass = 'disabled';
                statusText = 'Disabled';
            } else if (iface.up) {
                statusClass = 'connected';
                statusText = 'Connected';
            } else {
                statusClass = 'disconnected';
                statusText = 'Disconnected';
            }

            var ipText = iface.ip ? iface.ip : '(No IP address)';
            var hasIp = !!iface.ip;

            // Detect interface type for icon
            var iconClass = 'wan-iface-icon';
            var iconHtml = '';
            var device = (iface.device || '').toLowerCase();
            var proto = (iface.proto || '').toLowerCase();

            if (proto === 'qmi' || proto === 'mbim' || proto === 'ncm' || proto === '3g' || device.indexOf('wwan') >= 0) {
                iconClass += ' cellular';
            } else if (proto === 'wwan' || device.indexOf('wlan') >= 0 || device.indexOf('ra') === 0) {
                iconClass += ' wifi';
            } else if (device.indexOf('usb') >= 0 || device.indexOf('eth') >= 0 && proto === 'ncm') {
                iconClass += ' usb';
            } else {
                // Default ethernet icon
                iconHtml = '<div class="eth-row"><div class="eth-box"></div></div><div class="eth-row"><div class="eth-box"></div><div class="eth-box"></div></div>';
            }

            var rowHtml = '<div class="wan-policy-row" data-iface="' + iface.name + '" data-idx="' + idx + '">';
            // Left section (grey): grab icon, interface icon, name
            rowHtml += '<div class="wan-policy-left">';
            rowHtml += '<span class="wan-drag-handle">☰</span>';
            rowHtml += '<div class="' + iconClass + '">' + iconHtml + '</div>';
            rowHtml += '<span class="wan-policy-name" onclick="JamMonitor.showWanEditPopup(event, ' + idx + ')">' + escapeHtml(iface.name) + '</span>';
            rowHtml += '</div>';
            // Middle section (white): status
            rowHtml += '<div class="wan-policy-middle">';
            rowHtml += '<span class="wan-policy-status"><span class="wan-status-indicator ' + statusClass + '"></span>' + statusText + '</span>';
            rowHtml += '</div>';
            // Right section: IP address (clickable only if has IP)
            rowHtml += '<div class="wan-policy-right">';
            if (hasIp) {
                rowHtml += '<span class="wan-policy-ip" onclick="JamMonitor.showWanIpPopup(event, ' + idx + ')">' + escapeHtml(ipText) + '</span>';
            } else {
                rowHtml += '<span class="wan-policy-ip no-ip">' + escapeHtml(ipText) + '</span>';
            }
            rowHtml += '</div>';
            rowHtml += '</div>';

            dropzone.insertAdjacentHTML('beforeend', rowHtml);
        });

        initDragDrop();
    }

    function showWanIpPopup(e, idx) {
        e.stopPropagation();
        closeWanIpPopup();

        var iface = wanPolicyData[idx];
        if (!iface) return;

        var popup = document.createElement('div');
        popup.className = 'wan-ip-popup';
        popup.id = 'wan-ip-popup';

        var dnsText = (iface.dns && iface.dns.length > 0) ? iface.dns.join(', ') : '—';
        var subnetText = iface.subnet ? (cidrToSubnet(iface.subnet) || '/' + iface.subnet) : '—';

        popup.innerHTML = '<div class="wan-ip-popup-header">' +
            '<span>' + escapeHtml(iface.name) + ' ' + _('Details') + '</span>' +
            '<span class="wan-ip-popup-close" onclick="JamMonitor.closeWanIpPopup()">×</span>' +
            '</div>' +
            '<div class="wan-ip-popup-body">' +
            '<div class="wan-ip-popup-row"><span class="wan-ip-popup-label">' + _('Connection Type') + '</span><span class="wan-ip-popup-value">' + escapeHtml(iface.proto || '—') + '</span></div>' +
            '<div class="wan-ip-popup-row"><span class="wan-ip-popup-label">' + _('IP Address') + '</span><span class="wan-ip-popup-value">' + escapeHtml(iface.ip || '—') + '</span></div>' +
            '<div class="wan-ip-popup-row"><span class="wan-ip-popup-label">' + _('Subnet Mask') + '</span><span class="wan-ip-popup-value">' + escapeHtml(subnetText) + '</span></div>' +
            '<div class="wan-ip-popup-row"><span class="wan-ip-popup-label">' + _('Default Gateway') + '</span><span class="wan-ip-popup-value">' + escapeHtml(iface.gateway || '—') + '</span></div>' +
            '<div class="wan-ip-popup-row"><span class="wan-ip-popup-label">' + _('DNS Servers') + '</span><span class="wan-ip-popup-value">' + escapeHtml(dnsText) + '</span></div>' +
            '<div class="wan-ip-popup-row"><span class="wan-ip-popup-label">' + _('MTU') + '</span><span class="wan-ip-popup-value">' + escapeHtml(iface.mtu || '—') + '</span></div>' +
            '</div>';

        document.body.appendChild(popup);

        // Position near click
        var rect = e.target.getBoundingClientRect();
        var popupRect = popup.getBoundingClientRect();
        var left = rect.left;
        var top = rect.bottom + 5;

        // Keep on screen
        if (left + popupRect.width > window.innerWidth - 10) {
            left = window.innerWidth - popupRect.width - 10;
        }
        if (top + popupRect.height > window.innerHeight - 10) {
            top = rect.top - popupRect.height - 5;
        }

        popup.style.left = left + 'px';
        popup.style.top = top + 'px';

        // Close on outside click
        setTimeout(function() {
            document.addEventListener('click', closeWanIpPopupOnOutside);
        }, 10);
    }

    function closeWanIpPopup() {
        var popup = document.getElementById('wan-ip-popup');
        if (popup) popup.remove();
        document.removeEventListener('click', closeWanIpPopupOnOutside);
    }

    function closeWanIpPopupOnOutside(e) {
        var popup = document.getElementById('wan-ip-popup');
        if (popup && !popup.contains(e.target)) {
            closeWanIpPopup();
        }
    }

    // ============================================================
    // WAN Edit Popup
    // ============================================================
    function showWanEditPopup(e, idx) {
        e.stopPropagation();
        closeWanEditPopup();
        closeWanIpPopup();

        var iface = wanPolicyData[idx];
        if (!iface) return;

        var currentMode = wanPolicyModes[iface.name] || iface.multipath || 'off';
        var isEnabled = currentMode !== 'off';
        var proto = iface.proto || 'dhcp';
        var peerdns = iface.peerdns !== false; // default true (auto DNS)

        // Create overlay
        var overlay = document.createElement('div');
        overlay.className = 'wan-edit-overlay';
        overlay.id = 'wan-edit-overlay';
        overlay.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,0.4);z-index:10000;';
        overlay.onclick = closeWanEditPopup;
        document.body.appendChild(overlay);

        // Create popup
        var popup = document.createElement('div');
        popup.className = 'wan-edit-popup';
        popup.id = 'wan-edit-popup';
        popup.style.cssText = 'position:fixed;background:#fff;border-radius:6px;box-shadow:0 8px 32px rgba(0,0,0,0.2);z-index:10001;width:380px;max-width:90vw;font-size:12px;display:block;';
        popup.onclick = function(ev) { ev.stopPropagation(); };

        var priorityOptions = '<option value="master"' + (currentMode === 'master' ? ' selected' : '') + '>' + _('Primary') + '</option>' +
            '<option value="on"' + (currentMode === 'on' ? ' selected' : '') + '>' + _('Bonded') + '</option>' +
            '<option value="backup"' + (currentMode === 'backup' ? ' selected' : '') + '>' + _('Standby') + '</option>' +
            '<option value="off"' + (currentMode === 'off' ? ' selected' : '') + '>' + _('Disabled') + '</option>';

        var dnsServers = iface.dns || [];
        var dns1 = dnsServers[0] || '';
        var dns2 = dnsServers[1] || '';

        // Inline styles - compact version
        var sHeader = 'background:#2c3e50;color:#fff;padding:10px 14px;font-weight:600;font-size:13px;display:flex;justify-content:space-between;align-items:center;border-radius:6px 6px 0 0;';
        var sClose = 'cursor:pointer;font-size:18px;line-height:1;opacity:0.8;';
        var sBody = 'padding:12px 14px;max-height:70vh;overflow-y:auto;';
        var sSection = 'margin-bottom:12px;';
        var sSectionTitle = 'font-weight:600;font-size:10px;color:#7f8c8d;text-transform:uppercase;letter-spacing:0.5px;padding-bottom:6px;margin-bottom:8px;border-bottom:1px solid #ecf0f1;';
        var sRow = 'display:flex;align-items:center;margin-bottom:8px;';
        var sLabel = 'width:90px;color:#7f8c8d;font-size:11px;flex-shrink:0;';
        var sInput = 'flex:1;padding:6px 8px;border:1px solid #ddd;border-radius:4px;font-size:12px;font-family:inherit;box-sizing:border-box;min-width:0;';
        var sInputDisabled = sInput + 'background:#f5f5f5;color:#999;';
        var sSelect = 'flex:1;padding:6px 8px;border:1px solid #ddd;border-radius:4px;font-size:12px;background:#fff;cursor:pointer;box-sizing:border-box;min-width:0;';
        var sRadioLabel = 'margin-right:15px;cursor:pointer;color:#2c3e50;font-size:11px;';
        var sRadio = 'margin-right:4px;cursor:pointer;';
        var sStaticFields = 'margin-top:8px;padding:10px;background:#f8f9fa;border-radius:4px;' + (proto === 'static' ? '' : 'display:none;');
        var sDnsFields = 'margin-top:8px;padding:10px;background:#f8f9fa;border-radius:4px;' + (!peerdns ? '' : 'display:none;');
        var sActions = 'display:flex;justify-content:flex-end;gap:8px;padding-top:12px;margin-top:8px;border-top:1px solid #ecf0f1;';
        var sBtnCancel = 'padding:8px 16px;border:none;border-radius:4px;font-size:12px;font-weight:600;cursor:pointer;background:#ecf0f1;color:#7f8c8d;';
        var sBtnSave = 'padding:8px 16px;border:none;border-radius:4px;font-size:12px;font-weight:600;cursor:pointer;background:#3498db;color:#fff;';
        var sError = 'color:#e74c3c;font-size:11px;margin-top:6px;display:none;';
        var sInputSmall = 'width:70px;padding:6px 8px;border:1px solid #ddd;border-radius:4px;font-size:12px;font-family:inherit;box-sizing:border-box;text-align:center;';

        popup.innerHTML = '<div style="' + sHeader + '">' +
            '<span>' + _('Edit') + ' ' + escapeHtml(iface.name) + '</span>' +
            '<span style="' + sClose + '" onclick="JamMonitor.closeWanEditPopup()">×</span>' +
            '</div>' +
            '<div style="' + sBody + '">' +
            // Priority & Protocol row
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">' + _('Priority') + '</span>' +
            '<select id="wan-edit-priority" style="' + sSelect + '">' + priorityOptions + '</select>' +
            '</div>' +
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">' + _('Protocol') + '</span>' +
            '<select id="wan-edit-proto" style="' + sSelect + '" onchange="JamMonitor.toggleStaticFields()">' +
            '<option value="dhcp"' + (proto === 'dhcp' ? ' selected' : '') + '>DHCP</option>' +
            '<option value="static"' + (proto === 'static' ? ' selected' : '') + '>' + _('Static IP') + '</option>' +
            '</select>' +
            '</div>' +
            // Static IP fields (hidden by default)
            '<div id="wan-edit-static-fields" style="' + sStaticFields + '">' +
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">' + _('IP Address') + '</span>' +
            '<input type="text" id="wan-edit-ip" style="' + sInput + '" placeholder="192.168.1.100" value="' + escapeHtml(iface.ip || '') + '">' +
            '</div>' +
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">' + _('Subnet') + '</span>' +
            '<select id="wan-edit-netmask" style="' + sSelect + '">' +
            '<option value="255.255.255.0"' + (iface.subnet == 24 ? ' selected' : '') + '>/24</option>' +
            '<option value="255.255.255.128"' + (iface.subnet == 25 ? ' selected' : '') + '>/25</option>' +
            '<option value="255.255.255.192"' + (iface.subnet == 26 ? ' selected' : '') + '>/26</option>' +
            '<option value="255.255.254.0"' + (iface.subnet == 23 ? ' selected' : '') + '>/23</option>' +
            '<option value="255.255.0.0"' + (iface.subnet == 16 ? ' selected' : '') + '>/16</option>' +
            '</select>' +
            '</div>' +
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">' + _('Gateway') + '</span>' +
            '<input type="text" id="wan-edit-gateway" style="' + sInput + '" placeholder="192.168.1.1" value="' + escapeHtml(iface.gateway || '') + '">' +
            '</div>' +
            '</div>' +
            // DNS row
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">DNS</span>' +
            '<label style="' + sRadioLabel + '"><input type="radio" name="wan-edit-dns-mode" style="' + sRadio + '" value="auto"' + (peerdns ? ' checked' : '') + ' onchange="JamMonitor.toggleDnsFields()">' + _('Auto') + '</label>' +
            '<label style="' + sRadioLabel + '"><input type="radio" name="wan-edit-dns-mode" style="' + sRadio + '" value="custom"' + (!peerdns ? ' checked' : '') + ' onchange="JamMonitor.toggleDnsFields()">' + _('Custom') + '</label>' +
            '</div>' +
            '<div id="wan-edit-dns-fields" style="' + sDnsFields + '">' +
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">DNS 1</span>' +
            '<input type="text" id="wan-edit-dns1" style="' + sInput + '" placeholder="8.8.8.8" value="' + escapeHtml(dns1) + '">' +
            '</div>' +
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">DNS 2</span>' +
            '<input type="text" id="wan-edit-dns2" style="' + sInput + '" placeholder="8.8.4.4" value="' + escapeHtml(dns2) + '">' +
            '</div>' +
            '</div>' +
            // MTU
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">MTU</span>' +
            '<input type="text" id="wan-edit-mtu" style="' + sInputSmall + '" placeholder="1500" value="' + escapeHtml(iface.mtu || '') + '">' +
            '<span style="flex:1;"></span>' +
            '</div>' +
            // Actions
            '<div id="wan-edit-error" style="' + sError + '"></div>' +
            '<div style="' + sActions + '">' +
            '<button id="wan-edit-save-btn" style="' + sBtnSave + '" onclick="JamMonitor.saveWanSettings(' + idx + ')">' + _('Save and Apply') + '</button>' +
            '<button style="' + sBtnCancel + '" onclick="JamMonitor.closeWanEditPopup()">' + _('Cancel') + '</button>' +
            '</div>' +
            '</div>';

        document.body.appendChild(popup);

        // Center the popup using transform (works better on resize)
        popup.style.left = '50%';
        popup.style.top = '50%';
        popup.style.transform = 'translate(-50%, -50%)';
    }

    function toggleStaticFields() {
        var proto = document.getElementById('wan-edit-proto').value;
        var fields = document.getElementById('wan-edit-static-fields');
        if (fields) {
            fields.style.display = (proto === 'static') ? 'block' : 'none';
        }
    }

    function toggleDnsFields() {
        var mode = document.querySelector('input[name="wan-edit-dns-mode"]:checked');
        var fields = document.getElementById('wan-edit-dns-fields');
        if (fields && mode) {
            fields.style.display = (mode.value === 'custom') ? 'block' : 'none';
        }
    }

    function closeWanEditPopup() {
        var popup = document.getElementById('wan-edit-popup');
        var overlay = document.getElementById('wan-edit-overlay');
        if (popup) popup.remove();
        if (overlay) overlay.remove();
    }

    function saveWanSettings(idx) {
        var iface = wanPolicyData[idx];
        if (!iface) return;

        var saveBtn = document.getElementById('wan-edit-save-btn');
        var errorDiv = document.getElementById('wan-edit-error');
        saveBtn.disabled = true;
        saveBtn.textContent = _('Applying...');
        errorDiv.style.display = 'none';

        // Collect form data
        var priority = document.getElementById('wan-edit-priority').value;
        var proto = document.getElementById('wan-edit-proto').value;
        var dnsMode = document.querySelector('input[name="wan-edit-dns-mode"]:checked').value;

        var data = {
            iface: iface.name,
            multipath: priority,
            proto: proto,
            peerdns: dnsMode === 'auto'
        };

        // Static IP fields
        if (proto === 'static') {
            data.ipaddr = document.getElementById('wan-edit-ip').value.trim();
            data.netmask = document.getElementById('wan-edit-netmask').value;
            data.gateway = document.getElementById('wan-edit-gateway').value.trim();

            // Validate IP
            if (!data.ipaddr || !data.ipaddr.match(/^\d+\.\d+\.\d+\.\d+$/)) {
                errorDiv.textContent = _('Please enter a valid IP address');
                errorDiv.style.display = 'block';
                saveBtn.disabled = false;
                saveBtn.textContent = _('Save and Apply');
                return;
            }
            if (!data.gateway || !data.gateway.match(/^\d+\.\d+\.\d+\.\d+$/)) {
                errorDiv.textContent = _('Please enter a valid gateway address');
                errorDiv.style.display = 'block';
                saveBtn.disabled = false;
                saveBtn.textContent = _('Save and Apply');
                return;
            }
        }

        // Custom DNS
        if (dnsMode === 'custom') {
            var dns1 = document.getElementById('wan-edit-dns1').value.trim();
            var dns2 = document.getElementById('wan-edit-dns2').value.trim();
            data.dns = [];
            if (dns1) {
                if (!dns1.match(/^\d+\.\d+\.\d+\.\d+$/)) {
                    errorDiv.textContent = _('Please enter a valid DNS server 1 address');
                    errorDiv.style.display = 'block';
                    saveBtn.disabled = false;
                    saveBtn.textContent = _('Save and Apply');
                    return;
                }
                data.dns.push(dns1);
            }
            if (dns2) {
                if (!dns2.match(/^\d+\.\d+\.\d+\.\d+$/)) {
                    errorDiv.textContent = _('Please enter a valid DNS server 2 address');
                    errorDiv.style.display = 'block';
                    saveBtn.disabled = false;
                    saveBtn.textContent = _('Save and Apply');
                    return;
                }
                data.dns.push(dns2);
            }
        }

        // MTU
        var mtu = document.getElementById('wan-edit-mtu').value.trim();
        if (mtu) {
            var mtuNum = parseInt(mtu, 10);
            if (isNaN(mtuNum) || mtuNum < 576 || mtuNum > 9000) {
                errorDiv.textContent = _('MTU must be between 576 and 9000');
                errorDiv.style.display = 'block';
                saveBtn.disabled = false;
                saveBtn.textContent = _('Save and Apply');
                return;
            }
            data.mtu = mtuNum;
        }

        // Check if only priority changed (fast path using applyWanPolicy)
        var oldPriority = wanPolicyModes[iface.name] || iface.multipath || 'off';
        var onlyPriorityChanged = (
            priority !== oldPriority &&
            proto === (iface.proto || 'dhcp') &&
            dnsMode === (iface.peerdns !== false ? 'auto' : 'custom') &&
            !mtu
        );

        if (onlyPriorityChanged) {
            // Use the same fast path as drag and drop
            wanPolicyModes[iface.name] = priority;
            closeWanEditPopup();

            // Re-render to move the interface to the correct category
            renderWanPolicy();

            // Apply changes using the same function as drag and drop
            applyWanPolicy(iface.name);
            return;
        }

        // Full settings change - send to backend
        fetch(window.location.pathname + '/wan_edit', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data)
        })
        .then(function(r) { return r.json(); })
        .then(function(result) {
            if (result.success) {
                closeWanEditPopup();
                // Update local mode
                wanPolicyModes[iface.name] = priority;
                // Reload WAN policy data
                startWanPolicyPolling();
                loadWanPolicy(true);
            } else {
                errorDiv.textContent = result.error || 'Failed to save settings';
                errorDiv.style.display = 'block';
                saveBtn.disabled = false;
                saveBtn.textContent = _('Save and Apply');
            }
        })
        .catch(function(e) {
            console.error('Save WAN settings error:', e);
            errorDiv.textContent = 'Network error: ' + e.message;
            errorDiv.style.display = 'block';
            saveBtn.disabled = false;
            saveBtn.textContent = _('Save and Apply');
        });
    }

    function initDragDrop() {
        var rows = document.querySelectorAll('.wan-policy-row');
        var dropzones = document.querySelectorAll('.wan-category-dropzone');
        var draggedEl = null;
        var draggedIfaceName = null;
        var sourceZone = null;

        rows.forEach(function(row) {
            row.setAttribute('draggable', 'true');

            var handle = row.querySelector('.wan-drag-handle');

            // Track mousedown on handle to allow drag
            handle.addEventListener('mousedown', function(e) {
                row.dataset.canDrag = 'true';
            });

            // Reset on mouseup on the handle
            handle.addEventListener('mouseup', function(e) {
                row.dataset.canDrag = 'false';
            });

            row.addEventListener('dragstart', function(e) {
                if (row.dataset.canDrag !== 'true') {
                    e.preventDefault();
                    return false;
                }
                wanDragInProgress = true;
                draggedEl = row;
                draggedIfaceName = row.dataset.iface;
                sourceZone = row.parentElement;
                row.classList.add('dragging');
                e.dataTransfer.effectAllowed = 'move';
                e.dataTransfer.setData('text/plain', row.dataset.iface);
                // Use setTimeout to allow the drag image to be captured before visual changes
                setTimeout(function() {
                    row.style.opacity = '0.4';
                }, 0);
            });

            row.addEventListener('dragend', function(e) {
                row.classList.remove('dragging');
                row.style.opacity = '';
                row.dataset.canDrag = 'false';
                wanDragInProgress = false;
                dropzones.forEach(function(zone) {
                    zone.classList.remove('drag-over');
                });
                draggedEl = null;
                draggedIfaceName = null;
                sourceZone = null;
            });
        });

        dropzones.forEach(function(zone) {
            zone.addEventListener('dragover', function(e) {
                e.preventDefault();
                e.dataTransfer.dropEffect = 'move';
                this.classList.add('drag-over');
            });

            zone.addEventListener('dragenter', function(e) {
                e.preventDefault();
                this.classList.add('drag-over');
            });

            zone.addEventListener('dragleave', function(e) {
                // Only remove if leaving the dropzone entirely
                var rect = this.getBoundingClientRect();
                var x = e.clientX;
                var y = e.clientY;
                if (x < rect.left || x >= rect.right || y < rect.top || y >= rect.bottom) {
                    this.classList.remove('drag-over');
                }
            });

            zone.addEventListener('drop', function(e) {
                e.preventDefault();
                e.stopPropagation();
                this.classList.remove('drag-over');

                if (!draggedEl || !draggedIfaceName) return;

                var ifaceName = draggedIfaceName;
                var newPriority = this.dataset.priority;
                var oldPriority = wanPolicyModes[ifaceName];
                var targetZone = this;

                // Always move the element visually first (optimistic update)
                // This prevents the "kick back" effect
                if (oldPriority !== newPriority) {
                    // Primary auto-swap: if dropping into Primary and there's already one, swap it to Bonded
                    if (newPriority === 'master') {
                        var existingPrimary = targetZone.querySelector('.wan-policy-row');
                        if (existingPrimary && existingPrimary !== draggedEl) {
                            var existingName = existingPrimary.dataset.iface;
                            // Move existing primary to Bonded zone
                            var bondedZone = document.querySelector('.wan-category-dropzone[data-priority="on"]');
                            if (bondedZone) {
                                bondedZone.appendChild(existingPrimary);
                                wanPolicyModes[existingName] = 'on';
                                wanPendingChanges[existingName] = 'on';
                                // Set loading state on swapped interface
                                var swapIndicator = existingPrimary.querySelector('.wan-status-indicator');
                                var swapText = existingPrimary.querySelector('.wan-policy-status');
                                if (swapIndicator) swapIndicator.className = 'wan-status-indicator loading';
                                if (swapText) swapText.innerHTML = '<span class="wan-status-indicator loading"></span>Updating...';
                            }
                        }
                    }

                    // Update mode in memory and track as pending
                    wanPolicyModes[ifaceName] = newPriority;
                    wanPendingChanges[ifaceName] = newPriority;

                    // Move element to target dropzone immediately
                    targetZone.appendChild(draggedEl);

                    // Set loading state on the moved interface
                    var statusIndicator = draggedEl.querySelector('.wan-status-indicator');
                    var statusText = draggedEl.querySelector('.wan-policy-status');
                    if (statusIndicator) {
                        statusIndicator.className = 'wan-status-indicator loading';
                    }
                    if (statusText) {
                        statusText.innerHTML = '<span class="wan-status-indicator loading"></span>Updating...';
                    }

                    // Apply changes to backend
                    applyWanPolicy(ifaceName);
                }
            });
        });
    }

    function applyWanPolicy(changedIface) {
        // Build order and modes from current DOM state
        var order = [];
        var modes = {};

        // Collect interfaces in priority order (master first, then on, backup, off)
        ['master', 'on', 'backup', 'off'].forEach(function(priority) {
            var zone = document.querySelector('.wan-category-dropzone[data-priority="' + priority + '"]');
            if (zone) {
                zone.querySelectorAll('.wan-policy-row').forEach(function(row) {
                    var ifaceName = row.dataset.iface;
                    order.push(ifaceName);
                    modes[ifaceName] = priority;
                });
            }
        });

        fetch(window.location.pathname + '/wan_policy', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                order: order,
                modes: modes
            })
        })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            if (data.success) {
                // Start polling for status updates
                startWanPolicyPolling();
                // Initial reload after short delay
                setTimeout(function() { loadWanPolicy(true); }, 2000);
            } else {
                console.error('WAN policy error:', data.error);
                // Clear pending changes on error
                wanPendingChanges = {};
                // Reload to show current state
                loadWanPolicy(true);
            }
        })
        .catch(function(e) {
            console.error('WAN policy error:', e);
            // Clear pending changes on error
            wanPendingChanges = {};
            // Reload to show current state
            loadWanPolicy(true);
        });
    }

    // ============================================================
    // Advanced Settings (Failover + MPTCP)
    // ============================================================
    var advancedSettingsLoaded = false;

    function toggleAdvancedSettings() {
        var content = document.getElementById('wan-advanced-content');
        var arrow = document.getElementById('wan-advanced-arrow');
        if (!content || !arrow) return;

        var isVisible = content.classList.contains('visible');
        if (isVisible) {
            content.classList.remove('visible');
            arrow.classList.remove('open');
        } else {
            content.classList.add('visible');
            arrow.classList.add('open');
            // Load settings on first open
            if (!advancedSettingsLoaded) {
                loadAdvancedSettings();
                loadWanInterfaces();
            }
        }
    }

    function loadAdvancedSettings() {
        fetch(window.location.pathname + '/wan_advanced')
            .then(function(r) { return r.json(); })
            .then(function(data) {
                advancedSettingsLoaded = true;
                // Failover settings
                if (data.failover) {
                    var f = data.failover;
                    if (f.timeout !== undefined) document.getElementById('adv-timeout').value = f.timeout;
                    if (f.count !== undefined) document.getElementById('adv-count').value = f.count;
                    if (f.tries !== undefined) document.getElementById('adv-tries').value = f.tries;
                    if (f.interval !== undefined) document.getElementById('adv-interval').value = f.interval;
                    if (f.failure_interval !== undefined) document.getElementById('adv-failure-interval').value = f.failure_interval;
                    if (f.tries_up !== undefined) document.getElementById('adv-tries-up').value = f.tries_up;
                }
                // MPTCP settings
                if (data.mptcp) {
                    var m = data.mptcp;
                    if (m.scheduler) document.getElementById('adv-scheduler').value = m.scheduler;
                    if (m.path_manager) document.getElementById('adv-path-manager').value = m.path_manager;
                    if (m.congestion) document.getElementById('adv-congestion').value = m.congestion;
                    if (m.subflows !== undefined) document.getElementById('adv-subflows').value = m.subflows;
                    if (m.stale_loss_cnt !== undefined) document.getElementById('adv-stale-loss').value = m.stale_loss_cnt;
                }
            })
            .catch(function(e) {
                console.error('Failed to load advanced settings:', e);
            });
    }

    function saveAdvancedSettings(skipConfirm) {
        var saveBtn = document.getElementById('wan-advanced-save-btn');
        var errorDiv = document.getElementById('wan-advanced-error');
        var successDiv = document.getElementById('wan-advanced-success');

        // Get currently selected interfaces
        var checkboxes = document.querySelectorAll('#wan-iface-grid input[type="checkbox"]:checked');
        var selectedIfaces = [];
        checkboxes.forEach(function(cb) {
            selectedIfaces.push(cb.value);
        });

        // Check for active interfaces being removed (only if we have original list)
        if (!skipConfirm && wanIfacesOriginal.length > 0) {
            var removedActive = [];
            wanIfacesOriginal.forEach(function(ifaceName) {
                // Check if this interface is being unchecked
                if (selectedIfaces.indexOf(ifaceName) === -1) {
                    var ifaceData = wanIfacesData[ifaceName];
                    if (ifaceData && (ifaceData.is_up || ifaceData.multipath === 'master')) {
                        var status = ifaceData.multipath === 'master' ? 'primary' :
                                    (ifaceData.ip ? 'connected - ' + ifaceData.ip : 'up');
                        removedActive.push(ifaceName + ' (' + status + ')');
                    }
                }
            });

            if (removedActive.length > 0) {
                var msg = 'The following active interfaces will be removed from WAN Policy:\n\n' +
                          removedActive.join('\n') +
                          '\n\nThis will stop routing through these interfaces. Continue?';
                if (!confirm(msg)) {
                    return;  // User cancelled
                }
            }
        }

        saveBtn.disabled = true;
        saveBtn.textContent = _('Applying...');
        errorDiv.style.display = 'none';
        successDiv.style.display = 'none';

        var data = {
            failover: {
                timeout: parseInt(document.getElementById('adv-timeout').value, 10) || 1,
                count: parseInt(document.getElementById('adv-count').value, 10) || 1,
                tries: parseInt(document.getElementById('adv-tries').value, 10) || 2,
                interval: parseInt(document.getElementById('adv-interval').value, 10) || 1,
                failure_interval: parseInt(document.getElementById('adv-failure-interval').value, 10) || 2,
                tries_up: parseInt(document.getElementById('adv-tries-up').value, 10) || 2
            },
            mptcp: {
                scheduler: document.getElementById('adv-scheduler').value || 'default',
                path_manager: document.getElementById('adv-path-manager').value || 'fullmesh',
                congestion: document.getElementById('adv-congestion').value || 'bbr',
                subflows: parseInt(document.getElementById('adv-subflows').value, 10) || 8,
                stale_loss_cnt: parseInt(document.getElementById('adv-stale-loss').value, 10) || 4
            }
        };

        // Save both: WAN interfaces + advanced settings
        Promise.all([
            fetch(window.location.pathname + '/wan_ifaces', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ enabled: selectedIfaces })
            }).then(function(r) { return r.json(); }),
            fetch(window.location.pathname + '/wan_advanced', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(data)
            }).then(function(r) { return r.json(); })
        ])
        .then(function(results) {
            saveBtn.disabled = false;
            saveBtn.textContent = _('Save and Apply');
            var ifaceResult = results[0];
            var advResult = results[1];
            if (ifaceResult.success && advResult.success) {
                successDiv.textContent = 'All settings saved successfully!';
                successDiv.style.display = 'block';
                loadWanPolicy(); // Reload WAN policy to reflect changes
                setTimeout(function() { successDiv.style.display = 'none'; }, 3000);
            } else {
                errorDiv.textContent = ifaceResult.error || advResult.error || 'Failed to save settings';
                errorDiv.style.display = 'block';
            }
        })
        .catch(function(e) {
            console.error('Save advanced settings error:', e);
            saveBtn.disabled = false;
            saveBtn.textContent = _('Save and Apply');
            errorDiv.textContent = 'Network error: ' + e.message;
            errorDiv.style.display = 'block';
        });
    }

    function resetAdvancedSettings() {
        loadAdvancedSettings();
        loadWanInterfaces();
    }

    // ============================================================
    // WAN Interface Selector
    // ============================================================
    var wanIfacesOriginal = [];
    var wanIfacesData = {};  // Store full interface data for status checks

    function loadWanInterfaces() {
        var grid = document.getElementById('wan-iface-grid');
        if (!grid) return;

        grid.innerHTML = '<div style="color:#95a5a6;font-size:11px;grid-column:1/-1;text-align:center;padding:20px;">Loading interfaces...</div>';

        fetch(window.location.pathname + '/wan_ifaces')
            .then(function(r) { return r.json(); })
            .then(function(data) {
                wanIfacesOriginal = data.enabled || [];
                var allIfaces = data.all || [];

                // Store full interface data for status checks
                wanIfacesData = {};
                allIfaces.forEach(function(iface) {
                    wanIfacesData[iface.name] = iface;
                });

                if (allIfaces.length === 0) {
                    grid.innerHTML = '<div style="color:#95a5a6;font-size:11px;grid-column:1/-1;text-align:center;padding:20px;">No interfaces found</div>';
                    return;
                }

                var html = '';
                allIfaces.forEach(function(iface) {
                    var isChecked = wanIfacesOriginal.indexOf(iface.name) !== -1;
                    var checkedClass = isChecked ? ' checked' : '';
                    var checkedAttr = isChecked ? ' checked' : '';

                    // Build status badge
                    var statusBadge = '';
                    if (iface.multipath === 'master') {
                        statusBadge = '<span style="color:#3498db;font-size:9px;margin-left:5px;">' + _('(primary)') + '</span>';
                    } else if (iface.is_up && iface.ip) {
                        statusBadge = '<span style="color:#27ae60;font-size:9px;margin-left:5px;">' + _('(connected)') + '</span>';
                    } else if (iface.is_up) {
                        statusBadge = '<span style="color:#f39c12;font-size:9px;margin-left:5px;">' + _('(up)') + '</span>';
                    }

                    html += '<label class="wan-iface-item' + checkedClass + '" data-tooltip="' + iface.name + '">';
                    html += '<input type="checkbox" name="wan-iface" value="' + iface.name + '"' + checkedAttr + ' onchange="JamMonitor.updateIfaceItem(this)">';
                    html += '<span class="wan-iface-item-name">' + iface.name + statusBadge + '</span>';
                    if (iface.device) {
                        html += '<span class="wan-iface-item-device">' + iface.device + '</span>';
                    }
                    html += '</label>';
                });
                grid.innerHTML = html;
                updateIfaceStatus('');
            })
            .catch(function(e) {
                console.error('Failed to load interfaces:', e);
                grid.innerHTML = '<div style="color:#e74c3c;font-size:11px;grid-column:1/-1;text-align:center;padding:20px;">Failed to load interfaces</div>';
            });
    }

    function updateIfaceItem(checkbox) {
        var item = checkbox.closest('.wan-iface-item');
        if (checkbox.checked) {
            item.classList.add('checked');
        } else {
            item.classList.remove('checked');
        }
        updateIfaceStatus('');
    }

    function updateIfaceStatus(msg, isError) {
        var status = document.getElementById('wan-iface-status');
        if (status) {
            status.textContent = msg;
            status.style.color = isError ? '#e74c3c' : '#27ae60';
        }
    }

    function saveWanInterfaces() {
        var checkboxes = document.querySelectorAll('#wan-iface-grid input[type="checkbox"]:checked');
        var selected = [];
        checkboxes.forEach(function(cb) {
            selected.push(cb.value);
        });

        updateIfaceStatus('Saving...');

        fetch(window.location.pathname + '/wan_ifaces', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ enabled: selected })
        })
        .then(function(r) { return r.json(); })
        .then(function(result) {
            if (result.success) {
                wanIfacesOriginal = selected.slice();
                updateIfaceStatus('Saved! Reloading WAN Policy...');
                // Reload WAN policy to reflect changes
                loadWanPolicy();
                setTimeout(function() { updateIfaceStatus('Done!'); }, 500);
                setTimeout(function() { updateIfaceStatus(''); }, 2500);
            } else {
                updateIfaceStatus(result.error || 'Save failed', true);
            }
        })
        .catch(function(e) {
            console.error('Save WAN interfaces error:', e);
            updateIfaceStatus('Network error', true);
        });
    }

    function loadOmrStatus() {
        var frame = document.getElementById('omr-frame');
        // Load the OMR status page in iframe
        frame.src = '/cgi-bin/luci/admin/system/openmptcprouter/status';
    }

    // Chart loading spinner helpers
    function showChartLoading(period) {
        var loader = document.getElementById('loading-' + period);
        if (loader) loader.classList.add('active');
    }

    function hideChartLoading(period) {
        var loader = document.getElementById('loading-' + period);
        if (loader) loader.classList.remove('active');
    }

    function updateBandwidth(view) {
        if (view === 'bw-realtime') {
            var data = getFilteredThroughput();
            drawBandwidthChart('chart-realtime', data);
            updateBwTable('bw-rt-tbody', data.slice().reverse().slice(0, 15));
        } else if (view === 'bw-hourly') {
            loadVnstat('hourly');
        } else if (view === 'bw-daily') {
            loadVnstat('daily');
        } else if (view === 'bw-monthly') {
            loadVnstat('monthly');
        }
    }

    function loadVnstat(period) {
        // Show loading spinner
        showChartLoading(period);

        // Get selected interface from the appropriate dropdown
        var selectId = 'bw-' + period + '-iface';
        var sel = document.getElementById(selectId);
        var ifaceFilter = sel ? sel.value : 'all';

        // Build API params - if specific interface, include it
        var params = {};
        if (ifaceFilter !== 'all') {
            params.iface = ifaceFilter;
        }

        api('vnstat', params).then(function(data) {
            var tbodyId = 'bw-' + period + '-tbody';
            if (!data || data.error) {
                var tbody = document.getElementById(tbodyId);
                if (tbody) {
                    tbody.innerHTML = '<tr><td colspan="4" style="text-align:center;color:#999;">vnstat data not available</td></tr>';
                }
                hideChartLoading(period);
                return;
            }
            try {
                // data is already parsed JSON from api()
                var traffic = [];

                // Handle both single interface and all interfaces
                var ifaceList = data.interfaces || [];
                if (ifaceList.length === 0) {
                    throw new Error('No interfaces');
                }

                // If "all", aggregate across all WAN interfaces; otherwise use first (filtered) interface
                var aggregated = {};

                ifaceList.forEach(function(iface) {
                    // For "all", only include WAN interfaces
                    var ifaceName = iface.name || iface.id || '';
                    if (ifaceFilter === 'all') {
                        if (!ifaceName.match(/^lan[0-9]/) && !(ifaceName.indexOf('sfp') >= 0 && ifaceName.indexOf('lan') >= 0)) {
                            return; // Skip non-WAN
                        }
                    }

                    var trafficData = null;
                    if (period === 'hourly') trafficData = iface.traffic.hour;
                    else if (period === 'daily') trafficData = iface.traffic.day;
                    else if (period === 'monthly') trafficData = iface.traffic.month;

                    if (trafficData) {
                        trafficData.forEach(function(entry) {
                            var key, label, start_ts;
                            if (period === 'hourly') {
                                // Use timestamp as key to prevent merging same hour from different days
                                key = entry.timestamp;
                                label = String(entry.time.hour).padStart(2, '0') + ':00';
                                start_ts = entry.timestamp;
                            } else if (period === 'daily') {
                                key = entry.date.year + '-' + entry.date.month + '-' + entry.date.day;
                                label = entry.date.month + '-' + entry.date.day;
                                var d = new Date(entry.date.year, entry.date.month - 1, entry.date.day, 0, 0, 0);
                                start_ts = Math.floor(d.getTime() / 1000);
                            } else {
                                key = entry.date.year + '-' + String(entry.date.month).padStart(2, '0');
                                label = key;
                                var d = new Date(entry.date.year, entry.date.month - 1, 1, 0, 0, 0);
                                start_ts = Math.floor(d.getTime() / 1000);
                            }

                            if (!aggregated[key]) {
                                aggregated[key] = { label: label, rx: 0, tx: 0, start_ts: start_ts };
                            }
                            aggregated[key].rx += entry.rx || 0;
                            aggregated[key].tx += entry.tx || 0;
                        });
                    }
                });

                // Convert to array and sort by timestamp
                traffic = Object.values(aggregated);
                traffic.sort(function(a, b) { return a.start_ts - b.start_ts; });

                // Limit entries (take most recent)
                if (period === 'hourly') traffic = traffic.slice(-24);
                else if (period === 'daily') traffic = traffic.slice(-30);

                var chartId = 'chart-' + period;

                drawBarChart(chartId, traffic, period);
                updateVnstatTable(tbodyId, traffic, period);
                hideChartLoading(period);
            } catch (e) {
                var tbody = document.getElementById(tbodyId);
                if (tbody) {
                    tbody.innerHTML = '<tr><td colspan="4" style="text-align:center;color:#999;">vnstat data not available</td></tr>';
                }
                hideChartLoading(period);
            }
        }).catch(function() {
            hideChartLoading(period);
        });
    }

    // Shared chart constants
    var CHART_PAD = { top: 25, right: 20, bottom: 55, left: 70 };
    var CHART_LABEL_FONT = '9px sans-serif';
    var CHART_LABEL_COLOR = '#7f8c8d';

    // Color palettes for A/B testing
    var PALETTE_A = { download: '#3498db', upload: '#e67e22', total: '#9b59b6' }; // Blue/Orange/Purple
    var PALETTE_B = { download: '#1abc9c', upload: '#e74c3c', total: '#34495e' }; // Teal/Coral/Slate

    // Tooltip helpers
    var chartTooltip = null;
    function getChartTooltip() {
        if (!chartTooltip) {
            chartTooltip = document.createElement('div');
            chartTooltip.className = 'chart-tooltip';
            chartTooltip.style.display = 'none';
            document.body.appendChild(chartTooltip);
        }
        return chartTooltip;
    }

    function showChartTooltip(x, y, html) {
        var tip = getChartTooltip();
        tip.innerHTML = html;
        tip.style.display = 'block';
        // Position with viewport clamping
        var tipRect = tip.getBoundingClientRect();
        var left = x + 15;
        var top = y - 10;
        if (left + tipRect.width > window.innerWidth - 10) left = x - tipRect.width - 15;
        if (top + tipRect.height > window.innerHeight - 10) top = window.innerHeight - tipRect.height - 10;
        if (top < 10) top = 10;
        tip.style.left = left + 'px';
        tip.style.top = top + 'px';
    }

    function hideChartTooltip() {
        var tip = getChartTooltip();
        tip.style.display = 'none';
    }

    // Unified line chart function
    // options: { palette, period, formatValue, isRealtime, onClick }
    function drawLineChart(canvasId, data, options) {
        options = options || {};
        var palette = options.palette || PALETTE_A;
        var period = options.period || null;
        var formatValue = options.formatValue || formatBytesScale;
        var isRealtime = options.isRealtime || false;

        var canvas = document.getElementById(canvasId);
        if (!canvas) return;

        var rect = canvas.getBoundingClientRect();
        var ctx = canvas.getContext('2d');
        canvas.width = rect.width * 2;
        canvas.height = rect.height * 2;
        ctx.scale(2, 2);
        var w = rect.width, h = rect.height;

        var pad = CHART_PAD;
        var cw = w - pad.left - pad.right;
        var ch = h - pad.top - pad.bottom;

        // Store point positions for hover detection
        var pointPositions = [];

        // Clear and check data
        ctx.clearRect(0, 0, w, h);

        if (data.length === 0) {
            ctx.fillStyle = '#999';
            ctx.font = '14px sans-serif';
            ctx.textAlign = 'center';
            ctx.fillText(isRealtime ? _('Collecting data...') : _('No data available'), w/2, h/2);
            canvas.onmousemove = null;
            canvas.onmouseleave = null;
            canvas.onclick = null;
            canvas.style.cursor = 'default';
            return;
        }

        // Calculate max
        var max = 0;
        data.forEach(function(d) {
            var total = (d.rx || 0) + (d.tx || 0);
            if (total > max) max = total;
        });
        if (max === 0) max = 1000;
        max = max * 1.1;

        var step = data.length > 1 ? cw / (data.length - 1) : cw;

        // Grid + Y labels
        ctx.strokeStyle = '#ecf0f1';
        ctx.lineWidth = 1;
        ctx.fillStyle = '#7f8c8d';
        ctx.font = '10px sans-serif';
        ctx.textAlign = 'right';
        for (var i = 0; i <= 4; i++) {
            var y = pad.top + (ch / 4) * i;
            ctx.beginPath();
            ctx.moveTo(pad.left, y);
            ctx.lineTo(w - pad.right, y);
            ctx.stroke();
            var val = max - (max / 4) * i;
            ctx.fillText(formatValue(val), pad.left - 5, y + 3);
        }

        // X labels
        ctx.textAlign = 'right';
        ctx.fillStyle = CHART_LABEL_COLOR;
        ctx.font = CHART_LABEL_FONT;
        var labelStep = Math.ceil(data.length / 8);
        for (var j = 0; j < data.length; j += labelStep) {
            var x = pad.left + j * step;
            var d = data[j];
            var label = '';
            if (isRealtime && d.time) {
                var dt = new Date(d.time);
                label = String(dt.getHours()).padStart(2, '0') + ':' +
                        String(dt.getMinutes()).padStart(2, '0') + ':' +
                        String(dt.getSeconds()).padStart(2, '0');
            } else if (d.label) {
                label = d.label;
            }
            if (label) {
                ctx.save();
                ctx.translate(x, h - pad.bottom + 15);
                ctx.rotate(-Math.PI / 4);
                ctx.fillText(label, 0, 0);
                ctx.restore();
            }
        }

        // Calculate all point positions first
        data.forEach(function(d, idx) {
            var x = pad.left + idx * step;
            var rx = d.rx || 0;
            var tx = d.tx || 0;
            var total = rx + tx;
            pointPositions.push({
                x: x,
                yRx: pad.top + ch - (rx / max) * ch,
                yTx: pad.top + ch - (tx / max) * ch,
                yTotal: pad.top + ch - (total / max) * ch,
                rx: rx,
                tx: tx,
                total: total,
                label: isRealtime ? (d.time ? new Date(d.time).toLocaleTimeString() : '') : (d.label || ''),
                start_ts: d.start_ts,
                idx: idx
            });
        });

        // Draw lines - Download first, then Upload, then Total on top
        // Download line
        ctx.strokeStyle = palette.download;
        ctx.lineWidth = 2;
        ctx.beginPath();
        pointPositions.forEach(function(p, idx) {
            if (idx === 0) ctx.moveTo(p.x, p.yRx);
            else ctx.lineTo(p.x, p.yRx);
        });
        ctx.stroke();

        // Upload line
        ctx.strokeStyle = palette.upload;
        ctx.lineWidth = 2;
        ctx.beginPath();
        pointPositions.forEach(function(p, idx) {
            if (idx === 0) ctx.moveTo(p.x, p.yTx);
            else ctx.lineTo(p.x, p.yTx);
        });
        ctx.stroke();

        // Total line (on top, dashed)
        ctx.strokeStyle = palette.total;
        ctx.lineWidth = 2;
        ctx.setLineDash([5, 3]);
        ctx.beginPath();
        pointPositions.forEach(function(p, idx) {
            if (idx === 0) ctx.moveTo(p.x, p.yTotal);
            else ctx.lineTo(p.x, p.yTotal);
        });
        ctx.stroke();
        ctx.setLineDash([]);

        // Legend
        ctx.fillStyle = palette.download;
        ctx.fillRect(w - 130, 8, 12, 12);
        ctx.fillStyle = '#2c3e50';
        ctx.font = '11px sans-serif';
        ctx.textAlign = 'left';
        ctx.fillText(_('Download'), w - 115, 18);
        ctx.fillStyle = palette.upload;
        ctx.fillRect(w - 130, 24, 12, 12);
        ctx.fillStyle = '#2c3e50';
        ctx.fillText(_('Upload'), w - 115, 34);
        ctx.fillStyle = palette.total;
        ctx.fillRect(w - 130, 40, 12, 12);
        ctx.fillStyle = '#2c3e50';
        ctx.fillText(_('Total'), w - 115, 50);

        // Store state for hover redraw
        var chartState = {
            canvas: canvas, ctx: ctx, w: w, h: h, pad: pad, cw: cw, ch: ch,
            max: max, step: step, data: data, pointPositions: pointPositions,
            palette: palette, formatValue: formatValue, isRealtime: isRealtime
        };

        // Hover handlers - no click, just hover tooltip
        canvas.style.cursor = 'crosshair';
        canvas.onclick = null;

        canvas.onmousemove = function(e) {
            var canvasRect = canvas.getBoundingClientRect();
            var mouseX = e.clientX - canvasRect.left;
            var mouseY = e.clientY - canvasRect.top;

            // Find nearest point
            var nearest = null;
            var nearestDist = Infinity;
            pointPositions.forEach(function(p) {
                var dist = Math.abs(mouseX - p.x);
                if (dist < nearestDist) {
                    nearestDist = dist;
                    nearest = p;
                }
            });

            if (nearest && nearestDist < step + 10) {
                // Redraw chart
                redrawLineChart(chartState, nearest);

                // Show tooltip
                var html = '<div class="chart-tooltip-title">' + nearest.label + '</div>';
                html += '<div class="chart-tooltip-row"><span class="chart-tooltip-label" style="color:' + palette.download + '">▼ ' + _('Download') + '</span><span class="chart-tooltip-value">' + formatValue(nearest.rx) + '</span></div>';
                html += '<div class="chart-tooltip-row"><span class="chart-tooltip-label" style="color:' + palette.upload + '">▲ ' + _('Upload') + '</span><span class="chart-tooltip-value">' + formatValue(nearest.tx) + '</span></div>';
                html += '<div class="chart-tooltip-row"><span class="chart-tooltip-label" style="color:' + palette.total + '">● ' + _('Total') + '</span><span class="chart-tooltip-value">' + formatValue(nearest.total) + '</span></div>';
                showChartTooltip(canvasRect.left + nearest.x, e.clientY, html);
            } else {
                redrawLineChart(chartState, null);
                hideChartTooltip();
            }
        };

        canvas.onmouseleave = function() {
            redrawLineChart(chartState, null);
            hideChartTooltip();
        };
    }

    // Redraw chart with optional hover highlight
    function redrawLineChart(state, hoveredPoint) {
        var ctx = state.ctx;
        var w = state.w, h = state.h;
        var pad = state.pad, cw = state.cw, ch = state.ch;
        var max = state.max;
        var pointPositions = state.pointPositions;
        var palette = state.palette;
        var formatValue = state.formatValue;

        ctx.clearRect(0, 0, w, h);

        // Grid + Y labels
        ctx.strokeStyle = '#ecf0f1';
        ctx.lineWidth = 1;
        ctx.fillStyle = '#7f8c8d';
        ctx.font = '10px sans-serif';
        ctx.textAlign = 'right';
        for (var i = 0; i <= 4; i++) {
            var y = pad.top + (ch / 4) * i;
            ctx.beginPath();
            ctx.moveTo(pad.left, y);
            ctx.lineTo(w - pad.right, y);
            ctx.stroke();
            var val = max - (max / 4) * i;
            ctx.fillText(formatValue(val), pad.left - 5, y + 3);
        }

        // X labels
        ctx.textAlign = 'right';
        ctx.fillStyle = CHART_LABEL_COLOR;
        ctx.font = CHART_LABEL_FONT;
        var labelStep = Math.ceil(pointPositions.length / 8);
        for (var j = 0; j < pointPositions.length; j += labelStep) {
            var p = pointPositions[j];
            if (p.label) {
                ctx.save();
                ctx.translate(p.x, h - pad.bottom + 15);
                ctx.rotate(-Math.PI / 4);
                ctx.fillText(p.label, 0, 0);
                ctx.restore();
            }
        }

        // Hover crosshair
        if (hoveredPoint) {
            ctx.strokeStyle = 'rgba(52, 73, 94, 0.3)';
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(hoveredPoint.x, pad.top);
            ctx.lineTo(hoveredPoint.x, pad.top + ch);
            ctx.stroke();
        }

        // Download line
        ctx.strokeStyle = palette.download;
        ctx.lineWidth = 2;
        ctx.beginPath();
        pointPositions.forEach(function(p, idx) {
            if (idx === 0) ctx.moveTo(p.x, p.yRx);
            else ctx.lineTo(p.x, p.yRx);
        });
        ctx.stroke();

        // Upload line
        ctx.strokeStyle = palette.upload;
        ctx.lineWidth = 2;
        ctx.beginPath();
        pointPositions.forEach(function(p, idx) {
            if (idx === 0) ctx.moveTo(p.x, p.yTx);
            else ctx.lineTo(p.x, p.yTx);
        });
        ctx.stroke();

        // Total line (on top, dashed)
        ctx.strokeStyle = palette.total;
        ctx.lineWidth = 2;
        ctx.setLineDash([5, 3]);
        ctx.beginPath();
        pointPositions.forEach(function(p, idx) {
            if (idx === 0) ctx.moveTo(p.x, p.yTotal);
            else ctx.lineTo(p.x, p.yTotal);
        });
        ctx.stroke();
        ctx.setLineDash([]);

        // Hover dots
        if (hoveredPoint) {
            // Download dot
            ctx.fillStyle = palette.download;
            ctx.beginPath();
            ctx.arc(hoveredPoint.x, hoveredPoint.yRx, 5, 0, Math.PI * 2);
            ctx.fill();
            ctx.strokeStyle = '#fff';
            ctx.lineWidth = 2;
            ctx.stroke();

            // Upload dot
            ctx.fillStyle = palette.upload;
            ctx.beginPath();
            ctx.arc(hoveredPoint.x, hoveredPoint.yTx, 5, 0, Math.PI * 2);
            ctx.fill();
            ctx.strokeStyle = '#fff';
            ctx.stroke();

            // Total dot
            ctx.fillStyle = palette.total;
            ctx.beginPath();
            ctx.arc(hoveredPoint.x, hoveredPoint.yTotal, 5, 0, Math.PI * 2);
            ctx.fill();
            ctx.strokeStyle = '#fff';
            ctx.stroke();
        }

        // Legend
        ctx.fillStyle = palette.download;
        ctx.fillRect(w - 130, 8, 12, 12);
        ctx.fillStyle = '#2c3e50';
        ctx.font = '11px sans-serif';
        ctx.textAlign = 'left';
        ctx.fillText(_('Download'), w - 115, 18);
        ctx.fillStyle = palette.upload;
        ctx.fillRect(w - 130, 24, 12, 12);
        ctx.fillStyle = '#2c3e50';
        ctx.fillText(_('Upload'), w - 115, 34);
        ctx.fillStyle = palette.total;
        ctx.fillRect(w - 130, 40, 12, 12);
        ctx.fillStyle = '#2c3e50';
        ctx.fillText(_('Total'), w - 115, 50);
    }

    // Realtime chart - uses Palette A with rate formatting
    function drawBandwidthChart(canvasId, data) {
        drawLineChart(canvasId, data, {
            palette: PALETTE_A,
            formatValue: formatRateShort,
            isRealtime: true
        });
    }

    // Historical charts (hourly/daily/monthly) - now line charts
    function drawBarChart(canvasId, data, period) {
        drawLineChart(canvasId, data, {
            palette: PALETTE_A,
            period: period,
            formatValue: formatBytesScale,
            isRealtime: false
        });
    }

    function updateBwTable(tbodyId, data) {
        var tbody = document.getElementById(tbodyId);
        if (!tbody) return;
        var html = '';
        data.forEach(function(d) {
            var time = d.time ? new Date(d.time).toLocaleTimeString() : '--';
            html += '<tr><td>' + time + '</td>';
            html += '<td>' + formatRate(d.rx) + '</td>';
            html += '<td>' + formatRate(d.tx) + '</td>';
            html += '<td>' + formatRate(d.rx + d.tx) + '</td></tr>';
        });
        tbody.innerHTML = html || '<tr><td colspan="4" style="text-align:center;">No data</td></tr>';
    }

    function updateVnstatTable(tbodyId, data, period) {
        var tbody = document.getElementById(tbodyId);
        if (!tbody) return;

        // All periods: show newest -> oldest (most recent at top)
        var rows = (data || []).slice().reverse();

        function pad2(n) { return String(n).padStart(2, '0'); }

        function dayKeyFromStartTs(startTs) {
            var dt = new Date(startTs * 1000);
            dt.setHours(0, 0, 0, 0);
            return dt.getFullYear() + '-' + pad2(dt.getMonth() + 1) + '-' + pad2(dt.getDate());
        }

        function dayStartMsFromStartTs(startTs) {
            var dt = new Date(startTs * 1000);
            dt.setHours(0, 0, 0, 0);
            return dt.getTime();
        }

        function formatSeparatorLabel() {
            return _('Yesterday');
        }

        var html = '';
        var prevDayKey = null;

        rows.forEach(function(d) {
            // Insert a separator when the day changes (Hourly only)
            if (period === 'hourly' && d && d.start_ts) {
                var thisDayKey = dayKeyFromStartTs(d.start_ts);

                if (prevDayKey && thisDayKey !== prevDayKey) {
                    html += '<tr class="bw-day-separator">' +
                            '<td colspan="4"><span class="bw-day-separator-text">' + formatSeparatorLabel() + '</span></td>' +
                            '</tr>';
                }

                prevDayKey = thisDayKey;
            }

            html += '<tr><td>';
            if (d && d.start_ts) {
                html += '<span class="bw-time-link" data-range="' + period + '" data-start="' + d.start_ts + '">' + d.label + '</span>';
            } else {
                html += (d && d.label) ? d.label : '—';
            }
            html += '</td>';
            html += '<td>' + formatBytesScale((d && d.rx) ? d.rx : 0) + '</td>';
            html += '<td>' + formatBytesScale((d && d.tx) ? d.tx : 0) + '</td>';
            html += '<td>' + formatBytesScale(((d && d.rx) ? d.rx : 0) + ((d && d.tx) ? d.tx : 0)) + '</td></tr>';
        });

        tbody.innerHTML = html || '<tr><td colspan="4" style="text-align:center;">No data</td></tr>';

        // Click handler for clickable time links (ignore separator rows automatically)
        tbody.onclick = function(e) {
            var link = e.target.closest('.bw-time-link');
            if (link && link.dataset.start) {
                var range = link.dataset.range;
                var start = parseInt(link.dataset.start, 10);
                var label = link.textContent;
                showBandwidthBucketPopup(range, start, label);
            }
        };
    }

    function setScale(s) {
        scale = s;
        document.querySelectorAll('.jm-scale-btn').forEach(function(btn) {
            btn.classList.toggle('active', btn.dataset.scale === s);
        });
        // Redraw current bandwidth view
        if (currentView.startsWith('bw-')) updateBandwidth(currentView);
    }

    function setInterface(iface) {
        selectedIface = iface;
        // Redraw current bandwidth view with new interface
        if (currentView.startsWith('bw-')) {
            updateBandwidth(currentView);
        }
    }

    function formatUptime(seconds) {
        var d = Math.floor(seconds / 86400);
        var h = Math.floor((seconds % 86400) / 3600);
        var m = Math.floor((seconds % 3600) / 60);
        if (d > 0) return d + 'd ' + h + 'h ' + m + 'm';
        if (h > 0) return h + 'h ' + m + 'm';
        return m + 'm';
    }

    function formatRate(bytes) {
        // Convert bytes/sec to bits/sec (Mbps) for network speed display
        var bits = bytes * 8;
        if (scale === 'gb') {
            return (bits / 1000000000).toFixed(2) + ' Gbps';
        }
        if (bits < 1000) return bits.toFixed(0) + ' bps';
        if (bits < 1000000) return (bits / 1000).toFixed(1) + ' Kbps';
        if (bits < 1000000000) return (bits / 1000000).toFixed(1) + ' Mbps';
        return (bits / 1000000000).toFixed(2) + ' Gbps';
    }

    function formatRateShort(bytes) {
        // Convert bytes/sec to bits/sec (Mbps) for network speed display
        var bits = bytes * 8;
        if (bits < 1000) return bits.toFixed(0) + ' bps';
        if (bits < 1000000) return (bits / 1000).toFixed(0) + ' Kbps';
        if (bits < 1000000000) return (bits / 1000000).toFixed(0) + ' Mbps';
        return (bits / 1000000000).toFixed(1) + ' Gbps';
    }

    function formatBytesScale(bytes) {
        if (scale === 'gb') return (bytes / 1073741824).toFixed(2) + ' GB';
        if (bytes < 1024) return bytes.toFixed(0) + ' B';
        if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
        if (bytes < 1073741824) return (bytes / 1048576).toFixed(2) + ' MB';
        return (bytes / 1073741824).toFixed(2) + ' GB';
    }

    function exportDiag() {
        var btn = document.getElementById('diag-btn');
        var status = document.getElementById('diag-status');
        btn.disabled = true;
        btn.textContent = _('Generating...');
        status.innerHTML = '<span style="color:#7f8c8d;">Creating diagnostic bundle...</span>';
        window.location.href = window.location.pathname + '/diag';
        setTimeout(function() {
            btn.disabled = false;
            btn.textContent = 'Download Diagnostic Bundle';
            status.innerHTML = '<span style="color:#27ae60;">Download started. Check your downloads folder.</span>';
        }, 3000);
    }

    // History range selection
    function setHistoryRange(value, btn) {
        // Update active button (only within history card, not speed test buttons)
        var historyCard = document.getElementById('history-hours');
        if (historyCard) {
            var card = historyCard.closest('div[style*="border:2px solid"]');
            if (card) {
                card.querySelectorAll('.jm-quick-range').forEach(function(b) {
                    b.classList.remove('active');
                });
            }
        }
        if (btn) btn.classList.add('active');
        document.getElementById('history-hours').value = value;

        // Update estimates based on selected range
        updateHistoryEstimates(value);
    }

    // Calculate and display estimates for selected time range
    function updateHistoryEstimates(hours) {
        var estimateDiv = document.getElementById('history-estimate');
        if (!estimateDiv) return;

        if (!storageStatusCache || !storageStatusCache.entry_count) {
            estimateDiv.innerHTML = '<span style="color:#7f8c8d;">' + _('Calculating...') + '</span>';
            return;
        }

        var data = storageStatusCache;

        // Calculate entries for selected range
        // Collection is 1/minute, so max entries = hours * 60
        var maxEntries = hours * 60;

        // But we can't have more than what's in the database
        var availableEntries = Math.min(maxEntries, data.entry_count);

        // Estimate file size based on average bytes per entry
        // Average from actual data: ~200-300 bytes per entry in JSON format
        var avgBytesPerEntry = 250;
        if (data.database_size && data.entry_count > 0) {
            // Use actual ratio if available (database is more compact than JSON)
            avgBytesPerEntry = Math.round((data.database_size / data.entry_count) * 2.5);
        }
        var estimatedSize = availableEntries * avgBytesPerEntry;

        // Add overhead for syslog (~500KB avg) and current_state (~50KB)
        estimatedSize += 550000;

        // Format size
        var sizeStr;
        if (estimatedSize < 1024) {
            sizeStr = estimatedSize + ' B';
        } else if (estimatedSize < 1024 * 1024) {
            sizeStr = (estimatedSize / 1024).toFixed(1) + ' KB';
        } else {
            sizeStr = (estimatedSize / 1024 / 1024).toFixed(1) + ' MB';
        }

        // Check if we have enough data
        var rangeNote = '';
        if (maxEntries > data.entry_count) {
            var availableHours = Math.round(data.entry_count / 60);
            rangeNote = ' <span style="color:#f39c12;">(' + _('only') + ' ' + availableHours + 'h ' + _('available') + ')</span>';
        }

        estimateDiv.innerHTML = '~' + availableEntries.toLocaleString() + ' ' + _('entries') + ' &middot; ~' + sizeStr + rangeNote;
    }

    // Load storage status for diagnostics page
    function loadStorageStatus() {
        var infoDiv = document.getElementById('history-storage-info');
        var estimateDiv = document.getElementById('history-estimate');
        if (!infoDiv) return;

        // Show loading state for estimate
        if (estimateDiv) {
            estimateDiv.innerHTML = '<span style="color:#7f8c8d;">Loading...</span>';
        }

        api('storage_status').then(function(data) {
            if (!data) {
                infoDiv.innerHTML = '<span style="color:#e74c3c;">Unable to check storage status</span>';
                storageStatusCache = null;
                return;
            }
            if (!data.mounted) {
                infoDiv.innerHTML = '<span style="color:#e74c3c;">USB storage not mounted</span>';
                storageStatusCache = null;
                return;
            }
            if (!data.database_exists) {
                infoDiv.innerHTML = '<span style="color:#f39c12;">No data yet - collector starting...</span>';
                storageStatusCache = null;
                return;
            }

            // Cache the data for estimate calculations
            storageStatusCache = data;

            var parts = [];

            // Entry count (total in database)
            if (data.entry_count) {
                parts.push(data.entry_count.toLocaleString() + ' ' + _('total entries'));
            }

            // Data range (oldest to newest)
            if (data.oldest_ts && data.newest_ts) {
                var oldest = new Date(data.oldest_ts * 1000);
                var newest = new Date(data.newest_ts * 1000);
                parts.push(oldest.toLocaleDateString() + ' - ' + newest.toLocaleDateString());
            }

            // Database size
            if (data.database_size) {
                parts.push((data.database_size / 1024 / 1024).toFixed(1) + ' MB ' + _('on disk'));
            }

            // Collector status
            var collectorHtml = data.collector_running
                ? '<span style="color:#27ae60;">' + _('Collector running') + '</span>'
                : '<span style="color:#e74c3c;">' + _('Collector stopped') + '</span>';
            parts.push(collectorHtml);

            // Anomalies warning (last 24h)
            if (data.recent_anomalies > 0) {
                parts.push('<span style="color:#f39c12;">' + data.recent_anomalies + ' ' + _('anomalies (24h)') + '</span>');
            }

            infoDiv.innerHTML = parts.join(' &middot; ');

            // Update estimates for currently selected range
            var hours = document.getElementById('history-hours');
            if (hours) {
                updateHistoryEstimates(parseInt(hours.value, 10) || 24);
            }
        });
    }

    // Storage setup wizard state
    var selectedStorageDevice = null;

    // Check if storage setup is needed and show/hide banner
    function checkStorageSetup() {
        var banner = document.getElementById('storage-setup-banner');
        if (!banner) return;

        api('storage_status').then(function(data) {
            if (data && data.mounted && data.database_exists) {
                // Everything working - hide banner completely
                banner.style.display = 'none';
            } else {
                // Setup needed - show banner
                banner.style.display = 'block';
                banner.className = 'storage-setup-banner needs-setup';
                document.getElementById('storage-needs-setup').style.display = 'block';
                document.getElementById('storage-wizard').style.display = 'none';
                document.getElementById('storage-success').style.display = 'none';
            }
        });
    }

    // Show the storage setup wizard
    function showStorageSetup() {
        var banner = document.getElementById('storage-setup-banner');
        banner.className = 'storage-setup-banner';
        document.getElementById('storage-needs-setup').style.display = 'none';
        document.getElementById('storage-wizard').style.display = 'block';
        document.getElementById('storage-success').style.display = 'none';
        storageStep(1);
        loadStorageDevices();
    }

    // Hide the storage setup wizard
    function hideStorageSetup() {
        var banner = document.getElementById('storage-setup-banner');
        banner.style.display = 'none';
    }

    // Navigate to a specific step in the wizard
    function storageStep(step, keepSelection) {
        if (!keepSelection) {
            selectedStorageDevice = null;
        }
        for (var i = 1; i <= 3; i++) {
            var stepEl = document.getElementById('storage-step-' + i);
            var contentEl = document.getElementById('storage-content-' + i);
            if (stepEl) stepEl.className = 'storage-step' + (i === step ? ' active' : '');
            if (contentEl) contentEl.style.display = (i === step) ? 'block' : 'none';
        }
    }

    // Load available USB devices from the API
    function loadStorageDevices() {
        var list = document.getElementById('storage-device-list');
        if (!list) return;

        list.innerHTML = '<div style="text-align:center;color:#7f8c8d;padding:20px;">Scanning for USB devices...</div>';

        api('storage_devices').then(function(data) {
            if (!data || !data.devices || data.devices.length === 0) {
                list.innerHTML = '<div style="text-align:center;color:#e74c3c;padding:20px;">' +
                    'No USB devices detected.<br><small style="color:#7f8c8d;">Insert a USB drive and click Refresh.</small></div>' +
                    '<button onclick="JamMonitor.loadStorageDevices()" style="margin-top:10px;">Refresh</button>';
                return;
            }

            var html = '';
            data.devices.forEach(function(dev) {
                var statusBadge = '';
                if (dev.mounted) {
                    statusBadge = '<span style="background:#27ae60;color:#fff;padding:2px 8px;border-radius:4px;font-size:11px;margin-left:8px;">Mounted</span>';
                }
                if (dev.is_system) {
                    statusBadge = '<span style="background:#e74c3c;color:#fff;padding:2px 8px;border-radius:4px;font-size:11px;margin-left:8px;">System</span>';
                }

                html += '<div class="storage-device-option" data-device="' + dev.partition + '" onclick="JamMonitor.selectStorageDevice(this)">' +
                    '<div style="display:flex;justify-content:space-between;align-items:center;">' +
                    '<strong>' + dev.partition + '</strong>' + statusBadge +
                    '</div>' +
                    '<div style="color:#7f8c8d;font-size:13px;margin-top:4px;">' +
                    dev.size_human + (dev.filesystem ? ' &middot; ' + dev.filesystem : ' &middot; Unformatted') +
                    (dev.label ? ' &middot; ' + dev.label : '') +
                    '</div></div>';
            });

            html += '<button onclick="JamMonitor.loadStorageDevices()" style="margin-top:10px;background:#ecf0f1;color:#2c3e50;">Refresh Device List</button>';
            list.innerHTML = html;

            // Update buttons state
            updateStorageButtons();
        }).catch(function(err) {
            list.innerHTML = '<div style="text-align:center;color:#e74c3c;padding:20px;">Error loading devices</div>';
        });
    }

    // Handle device selection
    function selectStorageDevice(el) {
        var device = el.getAttribute('data-device');

        // Check if it's a system device
        var statusText = el.querySelector('span');
        if (statusText && statusText.textContent === 'System') {
            return; // Don't allow selecting system device
        }

        // Remove selection from all options
        var options = document.querySelectorAll('.storage-device-option');
        for (var i = 0; i < options.length; i++) {
            options[i].classList.remove('selected');
        }

        // Add selection to clicked option
        el.classList.add('selected');
        selectedStorageDevice = device;

        updateStorageButtons();
    }

    // Update button states based on selection
    function updateStorageButtons() {
        var formatBtn = document.getElementById('storage-format-btn');
        var useBtn = document.getElementById('storage-use-btn');

        if (formatBtn) formatBtn.disabled = !selectedStorageDevice;
        if (useBtn) useBtn.disabled = !selectedStorageDevice;
    }

    // Go to format step
    function goToFormatStep() {
        if (!selectedStorageDevice) return;
        storageStep(2, true);
        document.getElementById('storage-format-device').textContent = selectedStorageDevice;
        document.getElementById('storage-format-confirm').value = '';
        document.getElementById('storage-format-status').innerHTML = '';
    }

    // Format the selected device
    function formatDevice() {
        var confirmInput = document.getElementById('storage-format-confirm');
        var statusDiv = document.getElementById('storage-format-status');

        if (confirmInput.value !== 'FORMAT') {
            statusDiv.innerHTML = '<span style="color:#e74c3c;">Please type FORMAT to confirm</span>';
            return;
        }

        statusDiv.innerHTML = '<span style="color:#7f8c8d;">Formatting ' + selectedStorageDevice + '... This may take a moment.</span>';

        api('storage_format', { device: selectedStorageDevice }).then(function(data) {
            if (data && data.success) {
                statusDiv.innerHTML = '<span style="color:#27ae60;">Format complete!</span>';
                setTimeout(function() {
                    mountAndInit(selectedStorageDevice);
                }, 1000);
            } else {
                statusDiv.innerHTML = '<span style="color:#e74c3c;">Format failed: ' + (data && data.error ? data.error : 'Unknown error') + '</span>';
            }
        }).catch(function(err) {
            statusDiv.innerHTML = '<span style="color:#e74c3c;">Format failed: Network error</span>';
        });
    }

    // Use selected device without formatting (for already formatted drives)
    function useSelectedDevice() {
        if (!selectedStorageDevice) return;
        mountAndInit(selectedStorageDevice);
    }

    // Mount device and initialize database
    function mountAndInit(device) {
        storageStep(3, true);
        var statusDiv = document.getElementById('storage-init-status');
        statusDiv.innerHTML = '<span style="color:#7f8c8d;">Mounting ' + device + '...</span>';

        api('storage_mount', { device: device }).then(function(mountData) {
            if (!mountData || !mountData.success) {
                statusDiv.innerHTML = '<span style="color:#e74c3c;">Mount failed: ' + (mountData && mountData.error ? mountData.error : 'Unknown error') + '</span>';
                return;
            }

            statusDiv.innerHTML = '<span style="color:#7f8c8d;">Initializing database...</span>';

            api('storage_init').then(function(initData) {
                if (!initData || !initData.success) {
                    statusDiv.innerHTML = '<span style="color:#e74c3c;">Init failed: ' + (initData && initData.error ? initData.error : 'Unknown error') + '</span>';
                    return;
                }

                // Success!
                statusDiv.innerHTML = '<span style="color:#27ae60;">Setup complete!</span>';
                document.getElementById('storage-wizard').style.display = 'none';
                document.getElementById('storage-success').style.display = 'block';

                // After a delay, hide the banner and refresh storage status
                setTimeout(function() {
                    hideStorageSetup();
                    loadStorageStatus();
                }, 3000);
            });
        }).catch(function(err) {
            statusDiv.innerHTML = '<span style="color:#e74c3c;">Setup failed: Network error</span>';
        });
    }

    function downloadHistory() {
        var status = document.getElementById('history-status');
        var hours = document.getElementById('history-hours').value;
        var url = window.location.pathname + '/history?hours=' + hours;
        var filename = 'jammonitor-history-' + hours + 'h-' + new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19) + '.json';
        status.innerHTML = '<span style="color:#7f8c8d;">Fetching ' + hours + ' hour(s) of historical data...</span>';

        // First check if storage is available
        api('storage_status').then(function(storageData) {
            if (storageData && !storageData.mounted) {
                status.innerHTML = '<span style="color:#e74c3c;">Error: USB storage not mounted. Historical data unavailable.</span>';
                return;
            }
            if (storageData && !storageData.database_exists) {
                status.innerHTML = '<span style="color:#e74c3c;">Error: No historical database found. Metrics collector may not be running.</span>';
                return;
            }

            // Use fetch to download with proper error handling
            fetch(url)
                .then(function(response) {
                    if (!response.ok) {
                        throw new Error('Server error: ' + response.status);
                    }
                    return response.blob();
                })
                .then(function(blob) {
                    // Create download link
                    var downloadUrl = window.URL.createObjectURL(blob);
                    var a = document.createElement('a');
                    a.href = downloadUrl;
                    a.download = filename;
                    document.body.appendChild(a);
                    a.click();
                    document.body.removeChild(a);
                    window.URL.revokeObjectURL(downloadUrl);
                    status.innerHTML = '<span style="color:#27ae60;">Download complete!</span>';
                })
                .catch(function(err) {
                    console.error('History download error:', err);
                    status.innerHTML = '<span style="color:#e74c3c;">Download failed: ' + err.message + '</span>';
                });
        });
    }

    // === SPEED TEST FUNCTIONS ===

    function setSpeedTestSize(size, btn) {
        speedTestSize = size;
        // Update button states within the speed test card
        var card = btn.closest('div[style*="border:2px solid #27ae60"]');
        if (card) {
            card.querySelectorAll('.jm-quick-range').forEach(function(b) {
                b.classList.remove('active');
            });
        }
        btn.classList.add('active');
    }

    function populateSpeedTestWans() {
        var container = document.getElementById('speedtest-wans');
        if (!container) return;

        // Get WAN list from wan_policy endpoint
        api('wan_policy').then(function(data) {
            if (!data || !data.interfaces) {
                container.innerHTML = '<div style="color:#e74c3c;font-size:12px;text-align:center;padding:20px;">Failed to load WAN interfaces</div>';
                return;
            }

            var html = '';
            data.interfaces.forEach(function(wan) {
                // Only include active WANs (skip disabled and VPN tunnels)
                if (wan.multipath === 'off') return;
                if (wan.name.match(/^(omrvpn|tun[0-9]|tailscale)/i)) return;

                var lastDown = speedTestResults[wan.name] && speedTestResults[wan.name].download;
                var lastUp = speedTestResults[wan.name] && speedTestResults[wan.name].upload;

                var downStatus = lastDown ?
                    '<span class="result">' + lastDown.mbps.toFixed(1) + ' Mbps</span>' :
                    '<span>--</span>';
                var upStatus = lastUp ?
                    '<span class="result">' + lastUp.mbps.toFixed(1) + ' Mbps</span>' :
                    '<span>--</span>';

                var statusStyle = wan.up ? '' : 'opacity:0.5;';
                var disabled = wan.up ? '' : 'disabled';
                var ipDisplay = wan.ip || (wan.up ? _('Getting IP...') : _('No IP'));

                html += '<div class="speedtest-row" style="' + statusStyle + '" data-wan="' + escapeHtml(wan.name) + '">';
                html += '<span class="wan-ip">' + escapeHtml(ipDisplay) + '</span>';
                html += '<span class="wan-name" title="' + escapeHtml(wan.name) + '">' + escapeHtml(wan.name) + '</span>';
                html += '<div class="test-buttons">';
                html += '<button class="test-btn download" onclick="JamMonitor.runSpeedTest(\'' + escapeHtml(wan.name) + '\', \'download\')" ' + disabled + '>&#8595; ' + _('Download') + '</button>';
                html += '<button class="test-btn upload" onclick="JamMonitor.runSpeedTest(\'' + escapeHtml(wan.name) + '\', \'upload\')" ' + disabled + '>&#8593; ' + _('Upload') + '</button>';
                html += '</div>';
                html += '<div class="status" id="speedtest-status-' + escapeHtml(wan.name) + '">';
                html += '<div>&#8595; ' + downStatus + '</div>';
                html += '<div>&#8593; ' + upStatus + '</div>';
                html += '</div>';
                html += '</div>';
            });

            container.innerHTML = html || '<div style="color:#7f8c8d;font-size:12px;text-align:center;padding:20px;">No WAN interfaces found</div>';
        }).catch(function(err) {
            console.error('populateSpeedTestWans error:', err);
            container.innerHTML = '<div style="color:#e74c3c;font-size:12px;text-align:center;padding:20px;">Error loading WANs: ' + err.message + '</div>';
        });
    }

    function runSpeedTest(ifname, direction) {
        var key = ifname + '_' + direction;
        if (speedTestRunning[key]) return; // Already running

        // Disable buttons for this WAN
        var row = document.querySelector('.speedtest-row[data-wan="' + ifname + '"]');
        if (row) {
            row.querySelectorAll('.test-btn').forEach(function(btn) {
                btn.disabled = true;
            });
        }

        // Show spinner
        var statusEl = document.getElementById('speedtest-status-' + ifname);
        var arrow = direction === 'download' ? '&#8595;' : '&#8593;';
        var originalStatus = statusEl ? statusEl.innerHTML : '';
        if (statusEl) {
            statusEl.innerHTML = '<div>' + arrow + ' <span class="speedtest-spinner"></span> ' + _('Testing...') + '</div>';
        }

        // Calculate timeout based on size
        var timeout = speedTestSize <= 10 ? 15 : (speedTestSize <= 25 ? 30 : 60);

        // Start test
        var url = window.location.pathname + '/speedtest_start?ifname=' + encodeURIComponent(ifname) +
            '&direction=' + encodeURIComponent(direction) +
            '&size_mb=' + speedTestSize +
            '&timeout_s=' + timeout;

        fetch(url)
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (!data.ok) {
                    showSpeedTestError(data.error, data.install_hint);
                    restoreSpeedTestRow(ifname, originalStatus);
                    return;
                }

                speedTestRunning[key] = data.job_id;
                pollSpeedTestStatus(data.job_id, ifname, direction, originalStatus);
            })
            .catch(function(err) {
                showSpeedTestError('Request failed: ' + err.message);
                restoreSpeedTestRow(ifname, originalStatus);
            });
    }

    function pollSpeedTestStatus(job_id, ifname, direction, originalStatus) {
        var key = ifname + '_' + direction;
        var url = window.location.pathname + '/speedtest_status?job_id=' + encodeURIComponent(job_id);

        fetch(url)
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (!data.ok) {
                    showSpeedTestError(data.error);
                    finishSpeedTest(ifname, direction, null);
                    return;
                }

                if (data.state === 'running') {
                    // Continue polling
                    setTimeout(function() {
                        pollSpeedTestStatus(job_id, ifname, direction, originalStatus);
                    }, 1000);
                    return;
                }

                if (data.state === 'done') {
                    // Store result
                    if (!speedTestResults[ifname]) speedTestResults[ifname] = {};
                    speedTestResults[ifname][direction] = {
                        mbps: data.mbps,
                        bytes: data.bytes,
                        seconds: data.seconds,
                        timestamp: data.timestamp
                    };
                    finishSpeedTest(ifname, direction, data);
                } else if (data.state === 'error') {
                    showSpeedTestError(data.error);
                    finishSpeedTest(ifname, direction, null);
                }
            })
            .catch(function(err) {
                showSpeedTestError('Poll failed: ' + err.message);
                finishSpeedTest(ifname, direction, null);
            });
    }

    function finishSpeedTest(ifname, direction, result) {
        var key = ifname + '_' + direction;
        delete speedTestRunning[key];

        // Re-enable buttons
        var row = document.querySelector('.speedtest-row[data-wan="' + ifname + '"]');
        if (row) {
            row.querySelectorAll('.test-btn').forEach(function(btn) {
                btn.disabled = false;
            });
        }

        // Update status display
        var statusEl = document.getElementById('speedtest-status-' + ifname);
        if (!statusEl) return;

        var lastDown = speedTestResults[ifname] && speedTestResults[ifname].download;
        var lastUp = speedTestResults[ifname] && speedTestResults[ifname].upload;

        var downText = lastDown ?
            '<span class="result">' + lastDown.mbps.toFixed(1) + ' Mbps</span> <span style="font-size:10px;color:#95a5a6;">(' + (lastDown.bytes/1024/1024).toFixed(0) + 'MB, ' + lastDown.seconds.toFixed(1) + 's)</span>' :
            '<span>--</span>';
        var upText = lastUp ?
            '<span class="result">' + lastUp.mbps.toFixed(1) + ' Mbps</span> <span style="font-size:10px;color:#95a5a6;">(' + (lastUp.bytes/1024/1024).toFixed(0) + 'MB, ' + lastUp.seconds.toFixed(1) + 's)</span>' :
            '<span>--</span>';

        statusEl.innerHTML = '<div>&#8595; ' + downText + '</div><div>&#8593; ' + upText + '</div>';
    }

    function showSpeedTestError(message, installHint) {
        var errorEl = document.getElementById('speedtest-error');
        if (!errorEl) return;

        var html = escapeHtml(message);
        if (installHint) {
            html += '<br><code style="background:#fee;padding:2px 6px;border-radius:4px;margin-top:8px;display:inline-block;">' + escapeHtml(installHint) + '</code>';
        }

        errorEl.innerHTML = html;
        errorEl.style.display = 'block';

        // Auto-hide after 10 seconds
        setTimeout(function() {
            errorEl.style.display = 'none';
        }, 10000);
    }

    function restoreSpeedTestRow(ifname, originalStatus) {
        var row = document.querySelector('.speedtest-row[data-wan="' + ifname + '"]');
        if (row) {
            row.querySelectorAll('.test-btn').forEach(function(btn) {
                btn.disabled = false;
            });
        }
        var statusEl = document.getElementById('speedtest-status-' + ifname);
        if (statusEl && originalStatus) {
            statusEl.innerHTML = originalStatus;
        }
    }

    function escapeHtml(str) {
        var div = document.createElement('div');
        div.textContent = str || '';
        return div.innerHTML;
    }

    // Convert CIDR prefix length to dotted subnet mask (e.g., 24 -> 255.255.255.0)
    function cidrToSubnet(cidr) {
        if (!cidr && cidr !== 0) return null;
        var prefix = parseInt(cidr, 10);
        if (isNaN(prefix) || prefix < 0 || prefix > 32) return null;
        var mask = 0xFFFFFFFF << (32 - prefix) >>> 0;
        return [
            (mask >>> 24) & 0xFF,
            (mask >>> 16) & 0xFF,
            (mask >>> 8) & 0xFF,
            mask & 0xFF
        ].join('.');
    }

    // === BANDWIDTH BUCKET POPUP ===

    function showBandwidthBucketPopup(range, startTs, labelText) {
        // Remove existing popup if any
        var existing = document.getElementById('bw-bucket-popup-overlay');
        if (existing) existing.remove();

        // Create overlay
        var overlay = document.createElement('div');
        overlay.id = 'bw-bucket-popup-overlay';
        overlay.className = 'jm-popup-overlay';

        // Create popup
        var popup = document.createElement('div');
        popup.className = 'jm-popup bw-bucket-popup';
        popup.innerHTML = '<div class="jm-popup-header">' +
            '<span>' + _('Device Breakdown') + ' - ' + escapeHtml(labelText) + '</span>' +
            '<button class="jm-popup-close" onclick="JamMonitor.closeBwBucketPopup()">&times;</button>' +
            '</div>' +
            '<div class="jm-popup-body">' +
            '<div class="bw-bucket-loading"><div class="chart-spinner"></div><div>' + _('Loading device data...') + '</div></div>' +
            '</div>' +
            '<div class="jm-popup-footer">' +
            '<button class="jm-btn" onclick="JamMonitor.closeBwBucketPopup()">' + _('Close') + '</button>' +
            '</div>';

        overlay.appendChild(popup);
        document.body.appendChild(overlay);

        // Click outside to close
        overlay.onclick = function(e) {
            if (e.target === overlay) closeBwBucketPopup();
        };

        // Prevent popup clicks from closing
        popup.onclick = function(e) {
            e.stopPropagation();
        };

        // Fetch data
        api('history_clients', { range: range, start: startTs }).then(function(data) {
            var body = popup.querySelector('.jm-popup-body');

            if (!data || !data.ok || !data.devices || data.devices.length === 0) {
                body.innerHTML = '<div style="text-align:center;color:#7f8c8d;padding:40px;">' + _('No device data for this period.') + '<br><small style="color:#bdc3c7;">' + _('Data collection started recently or no traffic recorded.') + '</small></div>';
                return;
            }

            // Prepare devices with computed fields
            var devices = data.devices.map(function(dev) {
                var mac = dev.mac && dev.mac !== 'unknown' ? dev.mac.toUpperCase() : '—';
                var hostname = dev.hostname && dev.hostname !== '*' ? dev.hostname : '';
                var deviceType = detectDeviceType(hostname);
                var typeDisplay = deviceType !== 'unknown'
                    ? getDeviceIcon(deviceType) + ' ' + deviceType.charAt(0).toUpperCase() + deviceType.slice(1)
                    : '—';
                return {
                    ip: dev.ip,
                    mac: mac,
                    type: deviceType,
                    typeDisplay: typeDisplay,
                    rx: dev.rx || 0,
                    tx: dev.tx || 0,
                    total: (dev.rx || 0) + (dev.tx || 0)
                };
            });

            // Sort state - null means no sorting initially
            var sortColumn = null;
            var sortDirection = 'desc';

            // IP to number for proper sorting
            function ipToNumber(ip) {
                if (!ip || ip === '—') return 0;
                var parts = ip.split('.');
                if (parts.length !== 4) return 0;
                return ((parseInt(parts[0], 10) << 24) +
                        (parseInt(parts[1], 10) << 16) +
                        (parseInt(parts[2], 10) << 8) +
                        parseInt(parts[3], 10)) >>> 0;
            }

            // Sort function - returns unsorted if col is null
            function sortDevices(col, dir) {
                if (!col) return devices.slice();
                return devices.slice().sort(function(a, b) {
                    var valA, valB;
                    if (col === 'ip') {
                        valA = ipToNumber(a.ip);
                        valB = ipToNumber(b.ip);
                    } else if (col === 'mac' || col === 'type') {
                        valA = (a[col] || '').toLowerCase();
                        valB = (b[col] || '').toLowerCase();
                    } else {
                        valA = a[col] || 0;
                        valB = b[col] || 0;
                    }
                    if (valA === valB) return 0;
                    if (dir === 'asc') return valA > valB ? 1 : -1;
                    return valA < valB ? 1 : -1;
                });
            }

            // Render table
            function renderTable() {
                var sorted = sortDevices(sortColumn, sortDirection);
                var html = '<table class="bw-bucket-table">';
                html += '<thead><tr>';

                // Column definitions
                var columns = [
                    { key: 'ip', label: _('IP Address'), sortable: true },
                    { key: 'mac', label: _('MAC Address'), sortable: true },
                    { key: 'type', label: _('Type'), sortable: false },
                    { key: 'rx', label: _('Download'), sortable: true },
                    { key: 'tx', label: _('Upload'), sortable: true },
                    { key: 'total', label: _('Total'), sortable: true }
                ];

                columns.forEach(function(col) {
                    if (col.sortable) {
                        var isActive = sortColumn === col.key;
                        // Always show arrow placeholder to prevent column shifting
                        var arrowStyle = isActive ? '' : 'visibility:hidden;';
                        var arrowClass = isActive ? (sortDirection === 'asc' ? 'sort-asc' : 'sort-desc') : 'sort-asc';
                        var arrowHtml = '<span class="sort-icon ' + arrowClass + '" style="' + arrowStyle + '"></span>';
                        html += '<th class="sortable" data-sort="' + col.key + '" style="white-space:nowrap;">' + col.label + arrowHtml + '</th>';
                    } else {
                        html += '<th>' + col.label + '</th>';
                    }
                });

                html += '</tr></thead><tbody>';

                sorted.forEach(function(dev) {
                    html += '<tr>';
                    html += '<td style="font-family:monospace;font-size:12px;">' + escapeHtml(dev.ip) + '</td>';
                    html += '<td style="font-family:monospace;font-size:11px;">' + escapeHtml(dev.mac) + '</td>';
                    html += '<td>' + dev.typeDisplay + '</td>';
                    html += '<td>' + formatBytesCompact(dev.rx) + '</td>';
                    html += '<td>' + formatBytesCompact(dev.tx) + '</td>';
                    html += '<td style="font-weight:600;">' + formatBytesCompact(dev.total) + '</td>';
                    html += '</tr>';
                });

                html += '</tbody></table>';
                body.innerHTML = html;

                // Add click handlers for sorting
                body.querySelectorAll('th.sortable').forEach(function(th) {
                    th.onclick = function() {
                        var col = th.dataset.sort;
                        if (sortColumn === col) {
                            sortDirection = sortDirection === 'asc' ? 'desc' : 'asc';
                        } else {
                            sortColumn = col;
                            sortDirection = (col === 'mac' || col === 'type' || col === 'ip') ? 'asc' : 'desc';
                        }
                        renderTable();
                    };
                });
            }

            renderTable();
        }).catch(function(err) {
            var body = popup.querySelector('.jm-popup-body');
            body.innerHTML = '<div style="color:#e74c3c;text-align:center;padding:40px;">Error loading device data</div>';
        });
    }

    function closeBwBucketPopup() {
        var overlay = document.getElementById('bw-bucket-popup-overlay');
        if (overlay) overlay.remove();
    }

    document.addEventListener('DOMContentLoaded', init);

    return {
        switchView: switchView,
        exportDiag: exportDiag,
        downloadHistory: downloadHistory,
        setHistoryRange: setHistoryRange,
        setScale: setScale,
        setInterface: setInterface,
        loadVnstat: loadVnstat,
        loadWanPolicy: loadWanPolicy,
        showWanIpPopup: showWanIpPopup,
        closeWanIpPopup: closeWanIpPopup,
        showWanEditPopup: showWanEditPopup,
        closeWanEditPopup: closeWanEditPopup,
        saveWanSettings: saveWanSettings,
        toggleStaticFields: toggleStaticFields,
        toggleDnsFields: toggleDnsFields,
        toggleAdvancedSettings: toggleAdvancedSettings,
        saveAdvancedSettings: saveAdvancedSettings,
        resetAdvancedSettings: resetAdvancedSettings,
        loadWanInterfaces: loadWanInterfaces,
        saveWanInterfaces: saveWanInterfaces,
        updateIfaceItem: updateIfaceItem,
        toggleRemoteAps: toggleRemoteAps,
        editApList: editApList,
        cancelApEdit: cancelApEdit,
        saveApList: saveApList,
        toggleBypass: toggleBypass,
        saveClientChanges: saveClientChanges,
        resetClientChanges: resetClientChanges,
        setSpeedTestSize: setSpeedTestSize,
        runSpeedTest: runSpeedTest,
        closeBwBucketPopup: closeBwBucketPopup,
        checkStorageSetup: checkStorageSetup,
        showStorageSetup: showStorageSetup,
        hideStorageSetup: hideStorageSetup,
        loadStorageDevices: loadStorageDevices,
        selectStorageDevice: selectStorageDevice,
        goToFormatStep: goToFormatStep,
        formatDevice: formatDevice,
        useSelectedDevice: useSelectedDevice
    };
})();
