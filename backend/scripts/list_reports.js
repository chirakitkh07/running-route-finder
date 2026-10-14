const db = require('../config/db');

function listReports() {
  db.all('SELECT * FROM reports ORDER BY id DESC LIMIT 10', [], (err, rows) => {
    if (err) {
      console.error('DB error:', err);
      process.exit(1);
    }
    console.log(JSON.stringify(rows, null, 2));
    process.exit(0);
  });
}

listReports();
