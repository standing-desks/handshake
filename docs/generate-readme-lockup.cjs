// Documentation owns the lockup layout; assets/ owns the embedded symbol.
module.exports = function readmeLockup(symbol) {
  const embedded = symbol.trim().replace('<svg ', '<svg x="0" y="0" width="48" height="48" ');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="236" height="48" viewBox="0 0 236 48" role="img" aria-label="Handshake">
<style>text { fill: #202326; } @media (prefers-color-scheme: dark) { text { fill: #F4F1EB; } }</style>
${embedded}
<text x="60" y="34" font-family="system-ui, -apple-system, BlinkMacSystemFont, sans-serif" font-size="30" font-weight="600" letter-spacing="-1.35">Handshake</text>
</svg>
`;
};
