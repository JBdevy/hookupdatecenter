// Adapter identity takes precedence over an old DHCP address. A saved name
// identifies Wi-Fi/en0/Ethernet, not the SSID of the previously visited venue.
function selectAppNetwork(networks, config = {}, reservedIps = []) {
  const reserved = new Set(reservedIps.filter(Boolean));
  const available = networks.filter((item) => !reserved.has(item.ip));
  const name = String(config.preferredNetworkName || '').trim();
  const ip = String(config.preferredNetworkIp || '').trim();
  const preferred = name
    ? available.find((item) => item.name === name && item.ip === ip)
      || available.find((item) => item.name === name)
    : available.find((item) => ip && item.ip === ip);
  if ((name || ip) && !preferred) {
    return {
      selected: { name: name || 'Rede escolhida', ip: '127.0.0.1', score: 0,
        available: false, waitingForConnection: true },
      networks: available
    };
  }
  return {
    selected: preferred || available[0] || { name: 'Local', ip: '127.0.0.1', score: 0, available: false },
    networks: available
  };
}

function appNetworkSignature({ selected, networks }) {
  return JSON.stringify([selected.name, selected.ip, !!selected.waitingForConnection,
    networks.map((item) => [item.name, item.ip]).sort((a, b) =>
      JSON.stringify(a).localeCompare(JSON.stringify(b)))]);
}

module.exports = { selectAppNetwork, appNetworkSignature };
