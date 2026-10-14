const sqlite3 = require('sqlite3').verbose();
const path = require('path');
const fs = require('fs');

// Create a database file in the project root if it doesn't exist
const dbPath = path.resolve(__dirname, '../../database.sqlite');
const db = new sqlite3.Database(dbPath, (err) => {
    if (err) {
        console.error('Error opening database', err.message);
    } else {
        console.log(`Connected to the SQLite database at ${dbPath}`);
        
        // Initialize Tables
        db.serialize(() => {
            db.run(`CREATE TABLE IF NOT EXISTS routes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                userId TEXT NOT NULL,
                name TEXT,
                distance REAL,
                duration INTEGER,
                difficulty TEXT,
                coordinates TEXT NOT NULL,
                createdAt DATETIME DEFAULT CURRENT_TIMESTAMP
            )`);

            db.run(`CREATE TABLE IF NOT EXISTS reports (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                userId TEXT,
                type TEXT NOT NULL,
                lat REAL NOT NULL,
                lng REAL NOT NULL,
                description TEXT,
                status TEXT DEFAULT 'active',
                votes INTEGER DEFAULT 0,
                createdAt DATETIME DEFAULT CURRENT_TIMESTAMP
            )`);
            db.run(`CREATE TABLE IF NOT EXISTS ai_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                reportId INTEGER,
                action TEXT,
                content TEXT,
                confidence REAL,
                createdAt DATETIME DEFAULT CURRENT_TIMESTAMP
            )`);
            
            console.log('Database tables initialized.');
        });
    }
});

module.exports = db;
