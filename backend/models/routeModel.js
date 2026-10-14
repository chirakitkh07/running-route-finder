const { db } = require('../firebase');

const routesCollection = db.collection('routes');

class RouteModel {
  // Save a running route
  static async saveRoute(routeData) {
    try {
      const docRef = await routesCollection.add({
        ...routeData,
        createdAt: new Date().toISOString()
      });
      return { id: docRef.id, ...routeData };
    } catch (error) {
      throw new Error('Error saving route: ' + error.message);
    }
  }

  // Get saved routes for a specific user
  static async getRoutesByUser(userId) {
    try {
      const snapshot = await routesCollection.where('userId', '==', userId).get();
      if (snapshot.empty) return [];
      
      const routes = [];
      snapshot.forEach(doc => routes.push({ id: doc.id, ...doc.data() }));
      return routes;
    } catch (error) {
      throw new Error('Error fetching routes: ' + error.message);
    }
  }
}

module.exports = RouteModel;
