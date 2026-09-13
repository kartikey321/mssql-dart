package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"os"
	"time"

	_ "github.com/microsoft/go-mssqldb"
)

func mustExec(ctx context.Context, db execer, q string) {
	if _, err := db.ExecContext(ctx, q); err != nil {
		log.Fatalf("exec failed: %s: %v", q, err)
	}
}

type execer interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

func mustScalar(ctx context.Context, db querier, q string) int {
	var x int
	if err := db.QueryRowContext(ctx, q).Scan(&x); err != nil {
		log.Fatalf("query failed: %s: %v", q, err)
	}
	return x
}

type querier interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func main() {
	dsn := os.Getenv("MSSQL_DSN")
	if dsn == "" {
		dsn = "sqlserver://sa:Knex_Test1!@127.0.0.1:1433?database=knex_test&encrypt=disable"
	}
	iters := 30
	if v := os.Getenv("MSSQL_ITERS"); v != "" {
		fmt.Sscanf(v, "%d", &iters)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	db, err := sql.Open("sqlserver", dsn)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	fmt.Printf("go config: dsn=%s iterations=%d\n", dsn, iters)

	mustExec(ctx, db, "IF OBJECT_ID('probe_go_explicit') IS NOT NULL DROP TABLE probe_go_explicit")
	mustExec(ctx, db, "CREATE TABLE probe_go_explicit (id INT PRIMARY KEY, name NVARCHAR(50))")

	conn, err := db.Conn(ctx)
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()

	for i := 1; i <= iters; i++ {
		fmt.Printf("go explicit iter %d: begin\n", i)
		mustExec(ctx, conn, "BEGIN TRANSACTION")
		mustExec(ctx, conn, fmt.Sprintf("INSERT INTO probe_go_explicit VALUES (%d, 'a')", i))
		mustExec(ctx, conn, "COMMIT TRANSACTION")
		x := mustScalar(ctx, conn, "SELECT 1 AS x")
		fmt.Printf("go explicit iter %d: canary=%d\n", i, x)
	}
	fmt.Println("go explicit loop completed")

	mustExec(ctx, conn, "IF OBJECT_ID('probe_go_native') IS NOT NULL DROP TABLE probe_go_native")
	mustExec(ctx, conn, "CREATE TABLE probe_go_native (id INT PRIMARY KEY, name NVARCHAR(50))")
	for i := 1; i <= iters; i++ {
		fmt.Printf("go native iter %d: begin\n", i)
		tx, err := conn.BeginTx(ctx, nil)
		if err != nil {
			log.Fatalf("begin tx failed at iter %d: %v", i, err)
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf("INSERT INTO probe_go_native VALUES (%d, 'a')", i)); err != nil {
			_ = tx.Rollback()
			log.Fatalf("tx insert failed at iter %d: %v", i, err)
		}
		if err := tx.Commit(); err != nil {
			log.Fatalf("tx commit failed at iter %d: %v", i, err)
		}
		x := mustScalar(ctx, conn, "SELECT 1 AS x")
		fmt.Printf("go native iter %d: canary=%d\n", i, x)
	}
	fmt.Println("go native loop completed")
}
