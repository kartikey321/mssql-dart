'use strict'

const sql = require('../../node-mssql')

const encrypt = (process.env.MSSQL_ENCRYPT || 'true') === 'true'
const iterations = Number(process.env.MSSQL_ITERS || '30')

const config = {
  server: '127.0.0.1',
  port: 1433,
  user: 'sa',
  password: 'Knex_Test1!',
  database: 'knex_test',
  options: {
    encrypt,
    trustServerCertificate: true
  },
  pool: {
    max: 1,
    min: 1
  }
}

async function run() {
  const pool = await sql.connect(config)
  try {
    console.log(`node config: encrypt=${encrypt} iterations=${iterations}`)
    await pool.request().batch("IF OBJECT_ID('probe_node_explicit') IS NOT NULL DROP TABLE probe_node_explicit")
    await pool.request().batch("CREATE TABLE probe_node_explicit (id INT PRIMARY KEY, name NVARCHAR(50))")

    for (let i = 1; i <= iterations; i++) {
      console.log(`node explicit iter ${i}: begin`)
      await pool.request().batch('BEGIN TRANSACTION')
      await pool.request().batch(`INSERT INTO probe_node_explicit VALUES (${i}, N'a')`)
      await pool.request().batch('COMMIT TRANSACTION')
      const result = await pool.request().query('SELECT 1 AS x')
      console.log(`node explicit iter ${i}: canary=${result.recordset[0].x}`)
    }
    console.log('node explicit loop completed')

    await pool.request().batch("IF OBJECT_ID('probe_node_native') IS NOT NULL DROP TABLE probe_node_native")
    await pool.request().batch("CREATE TABLE probe_node_native (id INT PRIMARY KEY, name NVARCHAR(50))")
    for (let i = 1; i <= iterations; i++) {
      console.log(`node native iter ${i}: begin`)
      const tx = new sql.Transaction(pool)
      await tx.begin()
      try {
        await tx.request().query(`INSERT INTO probe_node_native VALUES (${i}, N'a')`)
        await tx.commit()
      } catch (err) {
        try { await tx.rollback() } catch (_) {}
        throw err
      }
      const result = await pool.request().query('SELECT 1 AS x')
      console.log(`node native iter ${i}: canary=${result.recordset[0].x}`)
    }
    console.log('node native loop completed')
  } finally {
    await pool.close()
  }
}

run().catch(err => {
  console.error(err && err.stack ? err.stack : err)
  process.exitCode = 1
})
