const http = require('http');

const port = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', service: 'billing-service' }));
    return;
  }
  res.writeHead(404);
  res.end('Not Found');
});

server.listen(port, () => {
  console.log(`billing-service stub listening on ${port}`);
});
