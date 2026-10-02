package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/engine"
	"github.com/VaderChen/FilmDevelop/internal/host"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	binary := flag.String("engine", engine.DefaultExecutable(), "原生引擎執行檔")
	method := flag.String("method", "capabilities", "capabilities、catalog、normalizeRecipe、editRecipe、projectRecipes 或 render")
	request := flag.String("request", "", "Recipe 或 RenderJob JSON 檔案")
	native := flag.Bool("native", false, "直接測試原生契約，不經 Go 配方服務")
	timeout := flag.Duration("timeout", 10*time.Minute, "單一工作逾時")
	flag.Parse()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	ctx, deadline := context.WithTimeout(ctx, *timeout)
	defer deadline()
	client := engine.New(*binary)
	defer client.Close()
	services, err := host.New(client)
	if err != nil {
		return err
	}
	var input json.RawMessage = json.RawMessage(`null`)
	if *request != "" {
		file, err := os.Open(*request)
		if err != nil {
			return err
		}
		defer file.Close()
		data, err := io.ReadAll(io.LimitReader(file, contract.MaxMessageBytes+1))
		if err != nil {
			return err
		}
		if len(data) > contract.MaxMessageBytes {
			return fmt.Errorf("請求超過大小限制")
		}
		input = data
	}
	var output json.RawMessage
	if !*native {
		output, err = services.Call(ctx, *method, input, nil)
	} else if *method == "render" {
		var job contract.RenderJob
		decoder := json.NewDecoder(bytes.NewReader(input))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&job); err != nil {
			return err
		}
		if decoder.Decode(new(any)) != io.EOF {
			return fmt.Errorf("請求包含多餘 JSON")
		}
		output, err = client.Render(ctx, job, nil)
	} else {
		output, err = client.Call(ctx, *method, input, nil)
	}
	if err != nil {
		return err
	}
	fmt.Println(string(output))
	return nil
}
