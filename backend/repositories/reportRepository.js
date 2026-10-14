const db = require('../config/db');

class ReportRepository {
  /**
   * Create a new safety/environmental report
   * @param {Object} reportData
   * @returns {Promise<Object>}
   */
  async createReport(reportData) {
    return new Promise((resolve, reject) => {
      const sql = `INSERT INTO reports (userId, type, lat, lng, description) 
                   VALUES (?, ?, ?, ?, ?)`;
      
      const values = [
        reportData.userId || null,
        reportData.type,
        reportData.lat,
        reportData.lng,
        reportData.description || null
      ];

      db.run(sql, values, function(err) {
        if (err) {
          return reject(err);
        }
        resolve({ id: this.lastID, ...reportData, status: 'active', votes: 0 });
      });
    });
  }

  /**
   * Get all active reports
   * @returns {Promise<Array>}
   */
  async getActiveReports() {
    return new Promise((resolve, reject) => {
      const sql = `SELECT * FROM reports WHERE status = 'active' ORDER BY createdAt DESC`;
      
      db.all(sql, [], (err, rows) => {
        if (err) {
          return reject(err);
        }
        resolve(rows);
      });
    });
  }

  /**
   * Update report status to resolved
   * @param {string|number} id
   * @returns {Promise<boolean>}
   */
  async updateReportStatus(id) {
    return new Promise((resolve, reject) => {
      const sql = `UPDATE reports SET status = 'resolved' WHERE id = ?`;
      
      db.run(sql, [id], function(err) {
        if (err) {
          return reject(err);
        }
        resolve(this.changes > 0);
      });
    });
  }

  /**
   * Increment or decrement votes
   * @param {string|number} id
   * @param {string} action 'verify' or 'reject'
   * @returns {Promise<Object>}
   */
  async updateReportVotes(id, action) {
    return new Promise((resolve, reject) => {
      const voteChange = action === 'verify' ? 1 : -1;
      const sql = `UPDATE reports SET votes = votes + ? WHERE id = ?`;
      
      db.run(sql, [voteChange, id], function(err) {
        if (err) {
          return reject(err);
        }
        
        // Fetch the updated report
        db.get(`SELECT * FROM reports WHERE id = ?`, [id], (err, row) => {
           if(err) return reject(err);
           resolve(row);
        });
      });
    });
  }
  
  /**
   * Get a report by id
   * @param {string|number} id
   * @returns {Promise<Object|null>}
   */
  async getReportById(id) {
    return new Promise((resolve, reject) => {
      db.get(`SELECT * FROM reports WHERE id = ?`, [id], (err, row) => {
        if (err) return reject(err);
        resolve(row || null);
      });
    });
  }

  /**
   * Get AI moderation logs for a report (most recent first)
   * @param {string|number} reportId
   * @returns {Promise<Array>}
   */
  async getAiLogs(reportId) {
    return new Promise((resolve, reject) => {
      const sql = `SELECT * FROM ai_logs WHERE reportId = ? ORDER BY id DESC`;
      db.all(sql, [reportId], (err, rows) => {
        if (err) return reject(err);
        resolve(rows || []);
      });
    });
  }
  /**
   * Expire reports older than the given hours
   * @param {number} hours
   * @returns {Promise<number>} Number of rows updated
   */
  async expireOldReports(hours = 24) {
    return new Promise((resolve, reject) => {
      const sql = `UPDATE reports SET status = 'expired' WHERE status = 'active' AND createdAt <= datetime('now', '-' || ? || ' hours')`;
      
      db.run(sql, [hours], function(err) {
        if (err) {
          return reject(err);
        }
        resolve(this.changes);
      });
    });
  }
}

module.exports = new ReportRepository();
