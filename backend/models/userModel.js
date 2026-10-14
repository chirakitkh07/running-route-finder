const { db } = require('../firebase');

const usersCollection = db.collection('users');

class UserModel {
  // Create a new user
  static async createUser(userId, userData) {
    try {
      await usersCollection.doc(userId).set({
        ...userData,
        createdAt: new Date().toISOString()
      });
      return { id: userId, ...userData };
    } catch (error) {
      throw new Error('Error creating user: ' + error.message);
    }
  }

  // Get user by ID
  static async getUserById(userId) {
    try {
      const doc = await usersCollection.doc(userId).get();
      if (!doc.exists) return null;
      return { id: doc.id, ...doc.data() };
    } catch (error) {
      throw new Error('Error fetching user: ' + error.message);
    }
  }
}

module.exports = UserModel;
