# TOOLS.md — NEXUS Tool Configuration

## Tool Philosophy
NEXUS uses tools purposefully — not speculatively. Before calling any tool, NEXUS states what it expects to find and why.

---

## Development Tools

### Code Execution
- **Primary**: Python (data science, automation, trading scripts)
- **Secondary**: Node.js (API testing, tooling)
- **Rule**: Always validate inputs before execution. Never run destructive operations without confirmation.

### Version Control
- Git with Conventional Commits standard
- Branch naming: `feature/`, `fix/`, `data/`, `trading/`
- FORGE always commits with descriptive messages — no "fix bug" commits

### Database
- PostgreSQL for transactional/retail data
- MongoDB for flexible document structures
- Redis for caching and session management
- **Rule**: GUARDIAN reviews all schema migrations before production apply

---

## Data & Analytics Tools

### Python Stack
```
pandas, numpy, scipy          # Data manipulation
scikit-learn, xgboost         # ML modeling  
statsmodels                   # Statistical analysis
plotly, matplotlib            # Visualization
sqlalchemy, psycopg2          # Database connectors
backtrader, ta-lib            # Trading/backtesting
```

### Pipeline Tools
- Apache Airflow for scheduled ETL
- dbt for data transformation
- Kafka for real-time streaming (when needed)

---

## Trading Tools

### Backtesting
- Python: backtrader or custom vectorized engine
- MQL4/5: MetaTrader strategy tester
- **Minimum**: 500+ trades in backtest sample for statistical validity

### Live Execution
- Broker API integration (OANDA, Interactive Brokers, or MT5)
- **Rule**: Paper trading validation ≥ 30 days before live deployment
- **Rule**: Position size calculator always runs before order submission

### Risk Engine
```python
# NEXUS enforces these checks on every QUANT recommendation:
max_risk_per_trade = 0.01    # 1% of account
max_open_positions = 5
max_correlated_pairs = 2     # Same direction, highly correlated pairs
max_daily_drawdown = 0.03    # 3% daily stop
```

---

## Infrastructure Tools

### Server (Linux VPS)
- Ubuntu 24.04 LTS preferred
- Docker + Docker Compose for service isolation
- Nginx as reverse proxy
- Certbot for SSL
- UFW for firewall management
- **GUARDIAN checklist before any VPS change:**
  - [ ] Backup taken
  - [ ] Rollback plan defined
  - [ ] Maintenance window confirmed with Alex

### Monitoring
- Prometheus + Grafana for metrics
- Uptime monitoring: ping every 60s
- Alert channels: defined by Alex preference
- **Forex systems**: PnL and drawdown alerts trigger in real-time

### CI/CD
- GitHub Actions for automated testing and deployment
- All PRs require: tests passing + FORGE review + NEXUS sign-off for production

---

## Communication & Reporting

### Status Dashboard (NEXUS Standard)
```
📊 NEXUS STATUS REPORT — [Date]

ACTIVE TASKS:
🟢 [Task] — [Agent] — On track, ETA [date]
🟡 [Task] — [Agent] — At risk: [reason] — Action: [what]
🔴 [Task] — [Agent] — BLOCKED: [reason] — Needs: Alex decision

COMPLETED THIS PERIOD:
✅ [Task] — [Outcome summary]

UPCOMING:
📅 [Task] — Starts [date] — Owner: [Agent]

ALERTS:
⚠️ [Any risks, anomalies, or items needing Alex attention]
```

---

## Tool Usage Rules (NEXUS Enforced)

1. **Never hardcode secrets** — use environment variables or a secrets manager
2. **Always log** — every agent action that touches data or infrastructure is logged
3. **Test before production** — staging environment is mandatory for web deployments
4. **Backtest before live** — no exceptions for trading strategies
5. **Document tool configs** — SCRIBE maintains a living runbook for all active tools
