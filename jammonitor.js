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

    // Interface list
    var interfaces = [];

    // WAN Policy data
    var wanPolicyData = [];
    var wanPolicyModes = {};
    var wanPolicyPollTimer = null;
    var wanPolicyPollEnd = 0;

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

    function exec(cmd) {
        return fetch(window.location.pathname + '/exec?cmd=' + encodeURIComponent(cmd))
            .then(function(r) { return r.text(); })
            .catch(function() { return ''; });
    }

    function detectEndpoints() {
        // Get WireGuard endpoint for VPS IP
        exec('wg show all endpoints 2>/dev/null').then(function(out) {
            var match = out.match(/(\d+\.\d+\.\d+\.\d+):/);
            if (match) {
                pingTargets.vps = match[1];
                document.getElementById('ping-vps-target').textContent = pingTargets.vps;
            }
        });

        // Get tunnel peer from OMR config or glorytun
        exec('uci get openmptcprouter.vps.ip 2>/dev/null || uci get glorytun.vpn.host 2>/dev/null').then(function(out) {
            var ip = out.trim();
            if (ip && !pingTargets.vps) {
                pingTargets.vps = ip;
                document.getElementById('ping-vps-target').textContent = ip;
            }
        });

        // Get tunnel peer IP - try multiple methods
        exec("ip route show dev tun0 2>/dev/null | grep -oE 'via [0-9.]+' | head -1 | cut -d' ' -f2").then(function(out) {
            var ip = out.trim();
            if (ip) {
                pingTargets.tunnel = ip;
                document.getElementById('ping-tunnel-target').textContent = ip;
            } else {
                // Try getting the remote end of tun0 (point-to-point)
                exec("ip addr show dev tun0 2>/dev/null | grep -oE 'peer [0-9.]+' | cut -d' ' -f2").then(function(peerOut) {
                    var peerIp = peerOut.trim();
                    if (peerIp) {
                        pingTargets.tunnel = peerIp;
                        document.getElementById('ping-tunnel-target').textContent = peerIp;
                    } else {
                        // Fallback: use .1 of the tun0 subnet
                        exec("ip addr show dev tun0 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2").then(function(tunIp) {
                            if (tunIp.trim()) {
                                var parts = tunIp.trim().split('.');
                                if (parts.length === 4) {
                                    parts[3] = '1';
                                    var gwIp = parts.join('.');
                                    pingTargets.tunnel = gwIp;
                                    document.getElementById('ping-tunnel-target').textContent = gwIp;
                                }
                            }
                        });
                    }
                });
            }
        });
    }

    function detectInterfaces() {
        exec("ip -br link | awk '{print $1}' | grep -vE '^lo$|^docker|^veth'").then(function(out) {
            interfaces = out.trim().split('\n').filter(function(i) { return i && i.trim(); }).map(function(iface) {
                // Strip @... suffix (e.g., lan3@eth0 -> lan3) to match /proc/net/dev names
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

            // Populate all interface selects
            ['bw-iface-select', 'bw-hourly-iface', 'bw-daily-iface', 'bw-monthly-iface'].forEach(function(id) {
                var sel = document.getElementById(id);
                if (sel) {
                    sel.innerHTML = '<option value="all">All WANs</option>';
                    wanIfaces.forEach(function(iface) {
                        if (iface) {
                            sel.innerHTML += '<option value="' + iface + '">' + iface + '</option>';
                        }
                    });
                }
            });
        }).catch(function(e) {
            console.error('detectInterfaces error:', e);
        });
    }

    function updateOverview() {
        // System health
        exec('cat /proc/loadavg').then(function(out) {
            var p = out.trim().split(/\s+/);
            if (p.length >= 3) {
                document.getElementById('sys-load').textContent = p[0] + ' / ' + p[1] + ' / ' + p[2];
            }
        });

        // CPU % - calculate over 1 second for stable average (not instant spike)
        exec("cat /proc/stat | grep '^cpu ' | awk '{print $2+$3+$4, $5}'; sleep 1; cat /proc/stat | grep '^cpu ' | awk '{print $2+$3+$4, $5}'").then(function(out) {
            var lines = out.trim().split('\n');
            if (lines.length === 2) {
                var first = lines[0].split(' ');
                var second = lines[1].split(' ');
                var busy1 = parseInt(first[0], 10);
                var idle1 = parseInt(first[1], 10);
                var busy2 = parseInt(second[0], 10);
                var idle2 = parseInt(second[1], 10);
                var busyDiff = busy2 - busy1;
                var idleDiff = idle2 - idle1;
                var total = busyDiff + idleDiff;
                if (total > 0) {
                    var cpu = (busyDiff / total) * 100;
                    document.getElementById('sys-cpu').textContent = cpu.toFixed(1) + '%';
                }
            }
        });

        exec('cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null').then(function(out) {
            var temp = parseInt(out.trim(), 10);
            if (!isNaN(temp)) {
                if (temp > 1000) temp = temp / 1000;
                document.getElementById('sys-temp-big').textContent = temp.toFixed(1) + ' C';
                var ind = document.getElementById('sys-indicator');
                if (temp > 80) ind.className = 'jm-indicator red';
                else if (temp > 65) ind.className = 'jm-indicator yellow';
                else ind.className = 'jm-indicator green';
            }
        });

        exec("free | awk '/Mem:/{printf \"%.1f\", $3/$2*100}'").then(function(out) {
            if (out.trim()) document.getElementById('sys-ram').textContent = out.trim() + '%';
        });

        exec('cat /proc/sys/net/netfilter/nf_conntrack_count; cat /proc/sys/net/netfilter/nf_conntrack_max').then(function(out) {
            var p = out.trim().split('\n');
            if (p.length === 2) document.getElementById('sys-conntrack').textContent = p[0] + ' / ' + p[1];
        });

        // VPN/Tunnel - check tun0 first (primary method)
        exec('ip addr show dev tun0 2>/dev/null').then(function(out) {
            var vpnInd = document.getElementById('vpn-indicator');
            var vpnStatus = document.getElementById('vpn-status');
            var vpnIface = document.getElementById('vpn-iface');
            var vpnIp = document.getElementById('vpn-ip');
            var vpnEndpoint = document.getElementById('vpn-endpoint');
            var vpnHandshake = document.getElementById('vpn-handshake');

            // Check if tun0 has an IPv4 address - that means it's UP
            var ipMatch = out.match(/inet\s+([0-9.]+)/);

            if (ipMatch) {
                // Tunnel is UP - has IPv4
                vpnInd.className = 'jm-indicator green';
                vpnStatus.textContent = 'Connected';
                vpnIface.textContent = 'tun0';
                vpnIp.textContent = ipMatch[1];

                // Try to get endpoint from OMR config
                exec('uci get openmptcprouter.vps.ip 2>/dev/null').then(function(vpsIp) {
                    if (vpsIp.trim()) {
                        vpnEndpoint.textContent = vpsIp.trim();
                    }
                });

                // Get VPN uptime from omrvpn interface status (actual tunnel uptime)
                exec('ifstatus omrvpn 2>/dev/null | jsonfilter -e "@.uptime" 2>/dev/null || echo ""').then(function(uptime) {
                    var secs = parseInt(uptime.trim(), 10);
                    if (!isNaN(secs) && secs > 0) {
                        var h = Math.floor(secs / 3600);
                        var m = Math.floor((secs % 3600) / 60);
                        vpnHandshake.textContent = h + 'h ' + m + 'm';
                    } else {
                        // Try tun0 interface uptime directly
                        exec('ifstatus tun0 2>/dev/null | jsonfilter -e "@.uptime" 2>/dev/null || echo ""').then(function(tunUp) {
                            var secs2 = parseInt(tunUp.trim(), 10);
                            if (!isNaN(secs2) && secs2 > 0) {
                                var h2 = Math.floor(secs2 / 3600);
                                var m2 = Math.floor((secs2 % 3600) / 60);
                                vpnHandshake.textContent = h2 + 'h ' + m2 + 'm';
                            } else {
                                // Show "Connected" if we can't determine uptime but tunnel is up
                                vpnHandshake.textContent = 'Connected';
                            }
                        });
                    }
                });
            } else {
                // tun0 doesn't have IP, check WireGuard as fallback
                exec('wg show 2>/dev/null').then(function(wgOut) {
                    if (wgOut.trim()) {
                        var wgIfaceMatch = wgOut.match(/interface:\s*(\S+)/);
                        var wgIface = wgIfaceMatch ? wgIfaceMatch[1] : 'wg0';

                        exec('ip addr show dev ' + wgIface + ' 2>/dev/null | grep -oE "inet [0-9.]+"').then(function(wgIp) {
                            if (wgIp.trim()) {
                                vpnInd.className = 'jm-indicator green';
                                vpnStatus.textContent = 'Connected (WG)';
                                vpnIface.textContent = wgIface;
                                vpnIp.textContent = wgIp.replace('inet ', '').trim();
                                // For WireGuard, get handshake time
                                var handshakeMatch = wgOut.match(/latest handshake:\s*(.+)/);
                                if (handshakeMatch) {
                                    vpnHandshake.textContent = handshakeMatch[1].trim();
                                } else {
                                    vpnHandshake.textContent = 'Connected';
                                }
                            } else {
                                // WireGuard exists but no IP - tunnel is down
                                vpnInd.className = 'jm-indicator red';
                                vpnStatus.textContent = 'No IP';
                                vpnIface.textContent = wgIface;
                                vpnIp.textContent = '--';
                                vpnHandshake.textContent = '--';
                            }
                        });

                        var endpointMatch = wgOut.match(/endpoint:\s*(\S+)/);
                        if (endpointMatch) vpnEndpoint.textContent = endpointMatch[1];
                    } else {
                        // No tun0 IP, no WireGuard - tunnel is down
                        vpnInd.className = 'jm-indicator red';
                        vpnStatus.textContent = 'Down';
                        vpnIface.textContent = 'tun0';
                        vpnIp.textContent = '--';
                        vpnHandshake.textContent = '--';
                    }
                });
            }
        });

        // WAN info - get route first, then verify with public IP check
        // Don't reset status during check - only update when result changes
        exec('ip route show default | head -1').then(function(out) {
            var gwMatch = out.match(/via\s+(\S+)/);
            var devMatch = out.match(/dev\s+(\S+)/);
            if (gwMatch) document.getElementById('wan-gw').textContent = gwMatch[1];
            if (devMatch) {
                document.getElementById('wan-iface').textContent = devMatch[1];
            } else {
                // No default route at all
                document.getElementById('wan-indicator').className = 'jm-indicator red';
                document.getElementById('wan-status').textContent = 'No Route';
                document.getElementById('wan-ip').textContent = '--';
                document.getElementById('wan-gw').textContent = '--';
                document.getElementById('wan-iface').textContent = '--';
            }
        });

        // Get actual public IP from external service (what the internet sees)
        exec('curl -s --max-time 3 ifconfig.me 2>/dev/null || curl -s --max-time 3 api.ipify.org 2>/dev/null || curl -s --max-time 3 icanhazip.com 2>/dev/null || echo ""').then(function(publicIp) {
            var ip = publicIp.trim();
            if (ip && ip.match(/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
                // Public IP retrieved - actually connected to internet
                document.getElementById('wan-ip').textContent = ip;
                document.getElementById('wan-indicator').className = 'jm-indicator green';
                document.getElementById('wan-status').textContent = 'Connected';
            } else {
                // Public IP check failed - no internet connectivity
                document.getElementById('wan-indicator').className = 'jm-indicator red';
                document.getElementById('wan-status').textContent = 'No Internet';
                // Fallback to interface IP if external check fails
                exec('ip route show default | head -1').then(function(out) {
                    var devMatch = out.match(/dev\s+(\S+)/);
                    if (devMatch) {
                        exec('ip addr show dev ' + devMatch[1] + ' 2>/dev/null | grep -oE "inet [0-9.]+" | cut -d" " -f2').then(function(ifaceIp) {
                            if (ifaceIp.trim()) {
                                document.getElementById('wan-ip').textContent = ifaceIp.trim() + ' (local)';
                            } else {
                                document.getElementById('wan-ip').textContent = '--';
                            }
                        });
                    } else {
                        document.getElementById('wan-ip').textContent = '--';
                    }
                });
            }
        });

        // Uptime
        exec('cat /proc/uptime').then(function(out) {
            var secs = parseFloat(out.split(' ')[0]);
            if (!isNaN(secs)) {
                document.getElementById('uptime-val').textContent = formatUptime(secs);
                // Calculate boot time
                var bootTime = new Date(Date.now() - secs * 1000);
                document.getElementById('boot-time').textContent = bootTime.toLocaleString();
            }
        });

        exec('date "+%Y-%m-%d %H:%M:%S"').then(function(out) {
            document.getElementById('local-time').textContent = out.trim();
        });

        // MPTCP
        exec('ip mptcp endpoint show 2>/dev/null | wc -l').then(function(out) {
            var count = parseInt(out.trim(), 10);
            var ind = document.getElementById('mptcp-indicator');
            if (!isNaN(count) && count > 0) {
                document.getElementById('mptcp-subflows').textContent = count;
                ind.className = 'jm-indicator green';
            } else {
                document.getElementById('mptcp-subflows').textContent = '0';
                ind.className = 'jm-indicator gray';
            }
        });

        // MPTCP connections count
        exec('ss -M 2>/dev/null | grep -c ESTAB || echo 0').then(function(out) {
            var count = parseInt(out.trim(), 10) || 0;
            document.getElementById('mptcp-conns').textContent = count + ' active';
        });

        // MPTCP interfaces in use
        exec('ip mptcp endpoint show 2>/dev/null | grep -oE "dev [a-z0-9]+" | cut -d" " -f2 | sort -u | tr "\\n" " "').then(function(out) {
            var ifaces = out.trim();
            document.getElementById('mptcp-ifaces').textContent = ifaces || 'none';
        });

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

        exec('ping -c1 -W1 ' + host + ' 2>/dev/null | grep -oE "time=[0-9.]+" | cut -d= -f2').then(function(out) {
            var ms = parseFloat(out.trim());

            if (!isNaN(ms)) {
                pingStats[key].received++;
                pingHistory[key].push({ time: Date.now(), value: ms });
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

        // Calculate loss percentage
        var loss = 0;
        if (stats.sent > 0) {
            loss = ((stats.sent - stats.received) / stats.sent * 100);
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
            valEl.textContent = 'timeout';
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
            valEl.textContent = 'timeout';
            indEl.className = 'jm-indicator red';
        }

        // Draw graph
        drawMiniGraph('graph-ping-' + key, history.map(function(h) { return h.value; }), '#3498db');
    }

    // Per-interface throughput history
    var ifaceThroughputHistory = {};

    function collectThroughput() {
        exec('cat /proc/net/dev').then(function(out) {
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

        Promise.all([
            exec('ip -br link'),
            exec('ip -br addr'),
            exec('ip route'),
            exec('cat /proc/net/dev'),
            exec('ls /sys/class/ieee80211/ 2>/dev/null || echo ""'),  // Get phy devices
            exec("uci show wireless 2>/dev/null | grep -E '=wifi-device|\.disabled='")  // Get radio names and disabled status
        ]).then(function(results) {
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
                var addr = hasAddr || 'None';
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
                        addr: radioInfo.disabled ? 'Disabled' : 'Enabled',
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
                    var stateText = iface.isUp ? 'UP' : 'DOWN';
                    s += '<div class="jm-block-compact">';
                    s += '<div class="jm-block-header" style="margin-bottom:4px;padding-bottom:4px;">';
                    s += '<span class="jm-indicator ' + indicatorClass + '" style="width:8px;height:8px;"></span>';
                    s += '<span class="jm-block-title" style="font-size:12px;">' + escapeHtml(iface.name) + '</span>';
                    s += '<span class="jm-block-status" style="font-size:9px;">' + iface.type + '</span>';
                    s += '</div>';
                    s += '<div class="jm-big-value">' + stateText + '</div>';
                    s += '<div class="jm-row"><span class="jm-label">IP</span><span class="jm-value" style="font-size:10px;">' + escapeHtml((iface.addr || '').split(' ')[0] || 'None') + '</span></div>';
                    s += '<div class="jm-row"><span class="jm-label">RX/TX</span><span class="jm-value">' + formatBytesCompact(iface.stats.rxBytes) + '/' + formatBytesCompact(iface.stats.txBytes) + '</span></div>';
                    s += '</div>';
                });
                s += '</div></div>';
                return s;
            }

            // Order: WAN, LAN/Bridge, VPN/Tunnel, WiFi, Physical/Other
            html += renderSection('WAN Interfaces (DHCP)', wans, '#e74c3c');
            html += renderSection('LAN / Bridge', lans.concat(bridges), '#27ae60');
            html += renderSection('VPN / Tunnel', vpns, '#9b59b6');
            html += renderSection('WiFi / Radios', radios, '#f39c12');
            if (physical.length > 0) html += renderSection('Physical / Other', physical, '#7f8c8d');

            grid.innerHTML = html || '<p style="color:#999;">No interfaces found</p>';

            // Routing table
            var routes = results[2].trim().split('\n');
            var routeHtml = '<table style="width:100%;font-size:11px;">';
            routeHtml += '<tr style="background:#f5f5f5;"><th style="padding:5px;text-align:left;">Destination</th><th style="padding:5px;">Gateway</th><th style="padding:5px;">Interface</th></tr>';
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

    function updateClients() {
        var tbody = document.getElementById('clients-tbody');
        Promise.all([
            exec('cat /tmp/dhcp.leases'),
            exec('cat /proc/net/arp'),
            exec('conntrack -L 2>/dev/null | grep -E "src=[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" || echo ""')
        ]).then(function(results) {
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
                    // First bytes= is usually src->dst (tx), second is dst->src (rx)
                    if (bytesMatches[0]) traffic[ip].tx += parseInt(bytesMatches[0].replace('bytes=', ''), 10);
                    if (bytesMatches[1]) traffic[ip].rx += parseInt(bytesMatches[1].replace('bytes=', ''), 10);
                }
            });

            // Parse DHCP leases
            results[0].trim().split('\n').forEach(function(line) {
                if (!line.trim()) return;
                var p = line.split(/\s+/);
                if (p.length >= 4) {
                    leases[p[2]] = { mac: p[1], hostname: p[3] || '*', ip: p[2] };
                }
            });

            // Parse ARP for additional entries
            results[1].trim().split('\n').forEach(function(line) {
                if (line.indexOf('IP address') >= 0) return;
                var p = line.split(/\s+/);
                if (p.length >= 4 && p[0].match(/^\d+\./)) {
                    if (!leases[p[0]]) leases[p[0]] = { mac: p[3], hostname: '*', ip: p[0] };
                }
            });

            var rows = '';
            Object.keys(leases).sort(function(a, b) {
                // Sort by IP numerically
                var aParts = a.split('.').map(Number);
                var bParts = b.split('.').map(Number);
                for (var i = 0; i < 4; i++) {
                    if (aParts[i] !== bParts[i]) return aParts[i] - bParts[i];
                }
                return 0;
            }).forEach(function(ip) {
                var c = leases[ip];
                var t = traffic[ip] || { rx: 0, tx: 0 };
                var rxStr = t.rx > 0 ? formatBytesCompact(t.rx) : '--';
                var txStr = t.tx > 0 ? formatBytesCompact(t.tx) : '--';
                rows += '<tr><td>' + escapeHtml(c.hostname) + '</td><td>' + escapeHtml(c.ip) + '</td>';
                rows += '<td style="font-family:monospace;font-size:12px;">' + escapeHtml(c.mac) + '</td>';
                rows += '<td>' + rxStr + '</td><td>' + txStr + '</td><td>LAN</td></tr>';
            });
            tbody.innerHTML = rows || '<tr><td colspan="6" style="text-align:center;color:#999;">No clients found</td></tr>';
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
                            worstApEl.textContent = 'All Good';
                            worstApEl.style.color = '#27ae60';
                        }
                    }
                }

                // Render local radios with utilization bars
                var localGrid = document.getElementById('wifi-local-grid');
                if (data.local_radios.length === 0) {
                    localGrid.innerHTML = '<p style="color:#999;margin:10px 0;">No local Wi-Fi radios detected</p>';
                } else {
                    var html = '';
                    data.local_radios.forEach(function(radio) {
                        var indicatorClass = radio.up ? 'green' : 'red';
                        var stateText = radio.up ? 'UP' : 'DOWN';
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
                        html += '<div class="jm-row"><span class="jm-label">Channel</span><span class="jm-value">' + escapeHtml(radio.channel) + '</span></div>';
                        html += '<div class="jm-row"><span class="jm-label">Tx Power</span><span class="jm-value">' + escapeHtml(radio.txpower) + '</span></div>';
                        html += '<div class="jm-row"><span class="jm-label">Clients</span><span class="jm-value">' + radio.clients + '</span></div>';
                        // Utilization bar
                        html += '<div class="jm-row" style="flex-direction:column;gap:2px;">';
                        html += '<span class="jm-label" style="width:100%;">Utilization ' + utilizationText + '</span>';
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
                        clientsTbody.innerHTML = '<tr><td colspan="6" style="text-align:center;color:#999;">No clients connected</td></tr>';
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
            header.textContent = '▼ Remote APs';
            collapsible.classList.add('expanded');
            updateRemoteAps();
        } else {
            content.style.display = 'none';
            header.textContent = '▶ Remote APs';
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
            listEl.innerHTML = '<div style="padding:20px;background:#f8f9fa;border-radius:6px;text-align:center;"><p style="color:#95a5a6;margin:0;">No remote APs configured</p><p style="color:#bdc3c7;font-size:11px;margin:5px 0 0;">Click "+ Add APs" below to monitor external access points</p></div>';
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
            '<span>' + escapeHtml(iface.name) + ' Details</span>' +
            '<span class="wan-ip-popup-close" onclick="JamMonitor.closeWanIpPopup()">×</span>' +
            '</div>' +
            '<div class="wan-ip-popup-body">' +
            '<div class="wan-ip-popup-row"><span class="wan-ip-popup-label">Connection Type</span><span class="wan-ip-popup-value">' + escapeHtml(iface.proto || '—') + '</span></div>' +
            '<div class="wan-ip-popup-row"><span class="wan-ip-popup-label">IP Address</span><span class="wan-ip-popup-value">' + escapeHtml(iface.ip || '—') + '</span></div>' +
            '<div class="wan-ip-popup-row"><span class="wan-ip-popup-label">Subnet Mask</span><span class="wan-ip-popup-value">' + escapeHtml(subnetText) + '</span></div>' +
            '<div class="wan-ip-popup-row"><span class="wan-ip-popup-label">Default Gateway</span><span class="wan-ip-popup-value">' + escapeHtml(iface.gateway || '—') + '</span></div>' +
            '<div class="wan-ip-popup-row"><span class="wan-ip-popup-label">DNS Servers</span><span class="wan-ip-popup-value">' + escapeHtml(dnsText) + '</span></div>' +
            '<div class="wan-ip-popup-row"><span class="wan-ip-popup-label">MTU</span><span class="wan-ip-popup-value">' + escapeHtml(iface.mtu || '—') + '</span></div>' +
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

        var priorityOptions = '<option value="master"' + (currentMode === 'master' ? ' selected' : '') + '>Primary</option>' +
            '<option value="on"' + (currentMode === 'on' ? ' selected' : '') + '>Bonded</option>' +
            '<option value="backup"' + (currentMode === 'backup' ? ' selected' : '') + '>Standby</option>' +
            '<option value="off"' + (currentMode === 'off' ? ' selected' : '') + '>Disabled</option>';

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
            '<span>Edit ' + escapeHtml(iface.name) + '</span>' +
            '<span style="' + sClose + '" onclick="JamMonitor.closeWanEditPopup()">×</span>' +
            '</div>' +
            '<div style="' + sBody + '">' +
            // Priority & Protocol row
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">Priority</span>' +
            '<select id="wan-edit-priority" style="' + sSelect + '">' + priorityOptions + '</select>' +
            '</div>' +
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">Protocol</span>' +
            '<select id="wan-edit-proto" style="' + sSelect + '" onchange="JamMonitor.toggleStaticFields()">' +
            '<option value="dhcp"' + (proto === 'dhcp' ? ' selected' : '') + '>DHCP</option>' +
            '<option value="static"' + (proto === 'static' ? ' selected' : '') + '>Static IP</option>' +
            '</select>' +
            '</div>' +
            // Static IP fields (hidden by default)
            '<div id="wan-edit-static-fields" style="' + sStaticFields + '">' +
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">IP Address</span>' +
            '<input type="text" id="wan-edit-ip" style="' + sInput + '" placeholder="192.168.1.100" value="' + escapeHtml(iface.ip || '') + '">' +
            '</div>' +
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">Subnet</span>' +
            '<select id="wan-edit-netmask" style="' + sSelect + '">' +
            '<option value="255.255.255.0"' + (iface.subnet == 24 ? ' selected' : '') + '>/24</option>' +
            '<option value="255.255.255.128"' + (iface.subnet == 25 ? ' selected' : '') + '>/25</option>' +
            '<option value="255.255.255.192"' + (iface.subnet == 26 ? ' selected' : '') + '>/26</option>' +
            '<option value="255.255.254.0"' + (iface.subnet == 23 ? ' selected' : '') + '>/23</option>' +
            '<option value="255.255.0.0"' + (iface.subnet == 16 ? ' selected' : '') + '>/16</option>' +
            '</select>' +
            '</div>' +
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">Gateway</span>' +
            '<input type="text" id="wan-edit-gateway" style="' + sInput + '" placeholder="192.168.1.1" value="' + escapeHtml(iface.gateway || '') + '">' +
            '</div>' +
            '</div>' +
            // DNS row
            '<div style="' + sRow + '">' +
            '<span style="' + sLabel + '">DNS</span>' +
            '<label style="' + sRadioLabel + '"><input type="radio" name="wan-edit-dns-mode" style="' + sRadio + '" value="auto"' + (peerdns ? ' checked' : '') + ' onchange="JamMonitor.toggleDnsFields()">Auto</label>' +
            '<label style="' + sRadioLabel + '"><input type="radio" name="wan-edit-dns-mode" style="' + sRadio + '" value="custom"' + (!peerdns ? ' checked' : '') + ' onchange="JamMonitor.toggleDnsFields()">Custom</label>' +
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
            '<button id="wan-edit-save-btn" style="' + sBtnSave + '" onclick="JamMonitor.saveWanSettings(' + idx + ')">Save and Apply</button>' +
            '<button style="' + sBtnCancel + '" onclick="JamMonitor.closeWanEditPopup()">Cancel</button>' +
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
        saveBtn.textContent = 'Applying...';
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
                errorDiv.textContent = 'Please enter a valid IP address';
                errorDiv.style.display = 'block';
                saveBtn.disabled = false;
                saveBtn.textContent = 'Save and Apply';
                return;
            }
            if (!data.gateway || !data.gateway.match(/^\d+\.\d+\.\d+\.\d+$/)) {
                errorDiv.textContent = 'Please enter a valid gateway address';
                errorDiv.style.display = 'block';
                saveBtn.disabled = false;
                saveBtn.textContent = 'Save and Apply';
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
                    errorDiv.textContent = 'Please enter a valid DNS server 1 address';
                    errorDiv.style.display = 'block';
                    saveBtn.disabled = false;
                    saveBtn.textContent = 'Save and Apply';
                    return;
                }
                data.dns.push(dns1);
            }
            if (dns2) {
                if (!dns2.match(/^\d+\.\d+\.\d+\.\d+$/)) {
                    errorDiv.textContent = 'Please enter a valid DNS server 2 address';
                    errorDiv.style.display = 'block';
                    saveBtn.disabled = false;
                    saveBtn.textContent = 'Save and Apply';
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
                errorDiv.textContent = 'MTU must be between 576 and 9000';
                errorDiv.style.display = 'block';
                saveBtn.disabled = false;
                saveBtn.textContent = 'Save and Apply';
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
                saveBtn.textContent = 'Save and Apply';
            }
        })
        .catch(function(e) {
            console.error('Save WAN settings error:', e);
            errorDiv.textContent = 'Network error: ' + e.message;
            errorDiv.style.display = 'block';
            saveBtn.disabled = false;
            saveBtn.textContent = 'Save and Apply';
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

    function saveAdvancedSettings() {
        var saveBtn = document.getElementById('wan-advanced-save-btn');
        var errorDiv = document.getElementById('wan-advanced-error');
        var successDiv = document.getElementById('wan-advanced-success');

        saveBtn.disabled = true;
        saveBtn.textContent = 'Applying...';
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

        // Save WAN interfaces first
        var checkboxes = document.querySelectorAll('#wan-iface-grid input[type="checkbox"]:checked');
        var selectedIfaces = [];
        checkboxes.forEach(function(cb) {
            selectedIfaces.push(cb.value);
        });

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
            saveBtn.textContent = 'Save and Apply';
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
            saveBtn.textContent = 'Save and Apply';
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

    function loadWanInterfaces() {
        var grid = document.getElementById('wan-iface-grid');
        if (!grid) return;

        grid.innerHTML = '<div style="color:#95a5a6;font-size:11px;grid-column:1/-1;text-align:center;padding:20px;">Loading interfaces...</div>';

        fetch(window.location.pathname + '/wan_ifaces')
            .then(function(r) { return r.json(); })
            .then(function(data) {
                wanIfacesOriginal = data.enabled || [];
                var allIfaces = data.all || [];

                if (allIfaces.length === 0) {
                    grid.innerHTML = '<div style="color:#95a5a6;font-size:11px;grid-column:1/-1;text-align:center;padding:20px;">No interfaces found</div>';
                    return;
                }

                var html = '';
                allIfaces.forEach(function(iface) {
                    var isChecked = wanIfacesOriginal.indexOf(iface.name) !== -1;
                    var checkedClass = isChecked ? ' checked' : '';
                    var checkedAttr = isChecked ? ' checked' : '';
                    html += '<label class="wan-iface-item' + checkedClass + '">';
                    html += '<input type="checkbox" name="wan-iface" value="' + iface.name + '"' + checkedAttr + ' onchange="JamMonitor.updateIfaceItem(this)">';
                    html += '<span class="wan-iface-item-name">' + iface.name + '</span>';
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
        // Get selected interface from the appropriate dropdown
        var selectId = 'bw-' + period + '-iface';
        var sel = document.getElementById(selectId);
        var ifaceFilter = sel ? sel.value : 'all';

        // Build vnstat command - if specific interface, query it directly
        var cmd = 'vnstat --json';
        if (ifaceFilter !== 'all') {
            cmd = 'vnstat -i ' + ifaceFilter + ' --json';
        }

        exec(cmd + ' 2>/dev/null').then(function(out) {
            try {
                var data = JSON.parse(out);
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
                            var key;
                            if (period === 'hourly') {
                                key = String(entry.time.hour).padStart(2, '0') + ':00';
                            } else if (period === 'daily') {
                                key = entry.date.month + '/' + entry.date.day;
                            } else {
                                key = entry.date.year + '-' + String(entry.date.month).padStart(2, '0');
                            }

                            if (!aggregated[key]) {
                                aggregated[key] = { label: key, rx: 0, tx: 0 };
                            }
                            aggregated[key].rx += entry.rx || 0;
                            aggregated[key].tx += entry.tx || 0;
                        });
                    }
                });

                // Convert to array and sort
                traffic = Object.values(aggregated);

                // Limit entries
                if (period === 'hourly') traffic = traffic.slice(-24);
                else if (period === 'daily') traffic = traffic.slice(-30);

                var chartId = 'chart-' + period;
                var tbodyId = 'bw-' + period + '-tbody';

                drawBarChart(chartId, traffic);
                updateVnstatTable(tbodyId, traffic);
            } catch (e) {
                var tbodyId = 'bw-' + period + '-tbody';
                var tbody = document.getElementById(tbodyId);
                if (tbody) {
                    tbody.innerHTML = '<tr><td colspan="4" style="text-align:center;color:#999;">vnstat data not available</td></tr>';
                }
            }
        });
    }

    // Shared chart constants
    var CHART_PAD = { top: 25, right: 20, bottom: 55, left: 70 };
    var CHART_LABEL_FONT = '9px sans-serif';
    var CHART_LABEL_COLOR = '#7f8c8d';

    function drawBandwidthChart(canvasId, data) {
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

        ctx.clearRect(0, 0, w, h);

        if (data.length < 2) {
            ctx.fillStyle = '#999';
            ctx.font = '14px sans-serif';
            ctx.textAlign = 'center';
            ctx.fillText('Collecting data...', w/2, h/2);
            return;
        }

        var max = 0;
        data.forEach(function(d) {
            var total = d.rx + d.tx;
            if (total > max) max = total;
        });
        if (max === 0) max = 1000;
        max = max * 1.1;

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
            ctx.fillText(formatRateShort(val), pad.left - 5, y + 3);
        }

        // X labels - consistent 45 degree rotation, HH:MM:SS format for realtime
        ctx.textAlign = 'right';
        ctx.fillStyle = CHART_LABEL_COLOR;
        ctx.font = CHART_LABEL_FONT;
        var step = cw / (data.length - 1);
        var labelStep = Math.ceil(data.length / 8); // Show ~8 labels max
        for (var j = 0; j < data.length; j += labelStep) {
            var x = pad.left + j * step;
            var d = data[j];
            if (d.time) {
                var dt = new Date(d.time);
                var label = String(dt.getHours()).padStart(2, '0') + ':' +
                            String(dt.getMinutes()).padStart(2, '0') + ':' +
                            String(dt.getSeconds()).padStart(2, '0');
                ctx.save();
                ctx.translate(x, h - pad.bottom + 15);
                ctx.rotate(-Math.PI / 4);
                ctx.fillText(label, 0, 0);
                ctx.restore();
            }
        }

        // Total line (behind others)
        ctx.strokeStyle = '#9b59b6';
        ctx.lineWidth = 1.5;
        ctx.setLineDash([4, 2]);
        ctx.beginPath();
        data.forEach(function(d, idx) {
            var x = pad.left + idx * step;
            var total = d.rx + d.tx;
            var y = pad.top + ch - (total / max) * ch;
            if (idx === 0) ctx.moveTo(x, y);
            else ctx.lineTo(x, y);
        });
        ctx.stroke();
        ctx.setLineDash([]);

        // RX line
        ctx.strokeStyle = '#27ae60';
        ctx.lineWidth = 2;
        ctx.beginPath();
        data.forEach(function(d, idx) {
            var x = pad.left + idx * step;
            var y = pad.top + ch - (d.rx / max) * ch;
            if (idx === 0) ctx.moveTo(x, y);
            else ctx.lineTo(x, y);
        });
        ctx.stroke();

        // TX line
        ctx.strokeStyle = '#e74c3c';
        ctx.beginPath();
        data.forEach(function(d, idx) {
            var x = pad.left + idx * step;
            var y = pad.top + ch - (d.tx / max) * ch;
            if (idx === 0) ctx.moveTo(x, y);
            else ctx.lineTo(x, y);
        });
        ctx.stroke();

        // Legend
        ctx.fillStyle = '#27ae60';
        ctx.fillRect(w - 130, 8, 12, 12);
        ctx.fillStyle = '#2c3e50';
        ctx.font = '11px sans-serif';
        ctx.textAlign = 'left';
        ctx.fillText('Download', w - 115, 18);
        ctx.fillStyle = '#e74c3c';
        ctx.fillRect(w - 130, 24, 12, 12);
        ctx.fillStyle = '#2c3e50';
        ctx.fillText('Upload', w - 115, 34);
        ctx.fillStyle = '#9b59b6';
        ctx.fillRect(w - 130, 40, 12, 12);
        ctx.fillStyle = '#2c3e50';
        ctx.fillText('Total', w - 115, 50);
    }

    function drawBarChart(canvasId, data) {
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

        ctx.clearRect(0, 0, w, h);

        if (data.length === 0) {
            ctx.fillStyle = '#999';
            ctx.font = '14px sans-serif';
            ctx.textAlign = 'center';
            ctx.fillText('No data available', w/2, h/2);
            return;
        }

        var max = 0;
        data.forEach(function(d) {
            var total = d.rx + d.tx;
            if (total > max) max = total;
        });
        if (max === 0) max = 1000000;
        max = max * 1.1;

        var barW = Math.min(30, cw / data.length * 0.7);
        var gap = (cw - barW * data.length) / (data.length + 1);

        // Grid
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
            ctx.fillText(formatBytesScale(val), pad.left - 5, y + 3);
        }

        // Bars - stacked (download on bottom, upload on top)
        data.forEach(function(d, idx) {
            var x = pad.left + gap + idx * (barW + gap);
            var rxH = (d.rx / max) * ch;
            var txH = (d.tx / max) * ch;

            // Download bar (bottom)
            ctx.fillStyle = '#27ae60';
            ctx.fillRect(x, pad.top + ch - rxH, barW, rxH);

            // Upload bar (stacked on top)
            ctx.fillStyle = '#e74c3c';
            ctx.fillRect(x, pad.top + ch - rxH - txH, barW, txH);

            // Label
            ctx.fillStyle = CHART_LABEL_COLOR;
            ctx.font = CHART_LABEL_FONT;
            ctx.textAlign = 'right';
            ctx.save();
            ctx.translate(x + barW / 2, h - pad.bottom + 15);
            ctx.rotate(-Math.PI / 4);
            ctx.fillText(d.label, 0, 0);
            ctx.restore();
        });

        // Legend
        ctx.fillStyle = '#27ae60';
        ctx.fillRect(w - 130, 8, 12, 12);
        ctx.fillStyle = '#2c3e50';
        ctx.font = '11px sans-serif';
        ctx.textAlign = 'left';
        ctx.fillText('Download', w - 115, 18);
        ctx.fillStyle = '#e74c3c';
        ctx.fillRect(w - 130, 24, 12, 12);
        ctx.fillStyle = '#2c3e50';
        ctx.fillText('Upload', w - 115, 34);
        ctx.fillStyle = '#9b59b6';
        ctx.fillRect(w - 130, 40, 12, 12);
        ctx.fillStyle = '#2c3e50';
        ctx.fillText('Total (stacked)', w - 115, 50);
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

    function updateVnstatTable(tbodyId, data) {
        var tbody = document.getElementById(tbodyId);
        if (!tbody) return;
        var html = '';
        data.slice().reverse().forEach(function(d) {
            html += '<tr><td>' + d.label + '</td>';
            html += '<td>' + formatBytesScale(d.rx) + '</td>';
            html += '<td>' + formatBytesScale(d.tx) + '</td>';
            html += '<td>' + formatBytesScale(d.rx + d.tx) + '</td></tr>';
        });
        tbody.innerHTML = html || '<tr><td colspan="4" style="text-align:center;">No data</td></tr>';
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
        btn.textContent = 'Generating...';
        status.innerHTML = '<span style="color:#7f8c8d;">Creating diagnostic bundle...</span>';
        window.location.href = window.location.pathname + '/diag';
        setTimeout(function() {
            btn.disabled = false;
            btn.textContent = 'Download Diagnostic Bundle';
            status.innerHTML = '<span style="color:#27ae60;">Download started. Check your downloads folder.</span>';
        }, 3000);
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

    document.addEventListener('DOMContentLoaded', init);

    return {
        switchView: switchView,
        exportDiag: exportDiag,
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
        saveApList: saveApList
    };
})();
