const express = require('express');
const cors = require('cors');
require('dotenv').config();

// Initialize DB (SQLite)
require('./config/db');
// Firebase is disabled while using local strategy
// require('./firebase');

const app = express();

// Middleware
app.use(cors());
app.use(express.json());

// Routes
const routeRoutes = require('./routes/routeRoutes');
const userRoutes = require('./routes/userRoutes');
const reportRoutes = require('./routes/reportRoutes');
const simulationRoutes = require('./routes/simulationRoutes');
const adminRoutes = require('./routes/adminRoutes');

app.use('/api/routes', routeRoutes);
app.use('/api/users', userRoutes);
app.use('/api/reports', reportRoutes);
app.use('/api/simulations', simulationRoutes);
app.use('/api/admin', adminRoutes);

app.get('/', (req, res) => {
    res.send('Running Route Finder API is healthy');
});

module.exports = app;
