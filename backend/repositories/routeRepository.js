const db = require('../config/db');

class RouteRepository {
  /**
   * Save a new route
   * @param {Object} routeData 
   * @returns {Promise<Object>}
   */
  async saveRoute(routeData) {
    return new Promise((resolve, reject) => {
      const sql = `INSERT INTO routes (userId, name, distance, duration, difficulty, coordinates) 
                   VALUES (?, ?, ?, ?, ?, ?)`;
      
      const values = [
        routeData.userId,
        routeData.name || 'Unnamed Route',
        routeData.distance || 0,
        routeData.duration || 0,
        routeData.difficulty || 'Unknown',
        JSON.stringify(routeData.coordinates)
      ];

      db.run(sql, values, function(err) {
        if (err) {
          return reject(err);
        }
        resolve({ id: this.lastID, ...routeData });
      });
    });
  }

  /**
   * Get all routes for a user
   * @param {string} userId 
   * @returns {Promise<Array>}
   */
  async getRoutesByUser(userId) {
    return new Promise((resolve, reject) => {
      const sql = `SELECT * FROM routes WHERE userId = ? ORDER BY createdAt DESC`;
      
      db.all(sql, [userId], (err, rows) => {
        if (err) {
          return reject(err);
        }
        
        // Parse coordinates from JSON string back to array
        const processedRows = rows.map(row => ({
          ...row,
          coordinates: JSON.parse(row.coordinates)
        }));
        
        resolve(processedRows);
      });
    });
  }
}

module.exports = new RouteRepository();
