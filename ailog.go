package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

func helpfile() {
	fmt.Println("Usage: ailog <command> [arguments]")
	fmt.Println("-f --file <file>")
	fmt.Println("-h --help for show help")
	fmt.Println("-c --config Setting config file")
}

type config struct {
	APIkey  string `json:"apikey"`
	Model   string `json:"model"`
	BaseURL string `json:"base_url"`
}
type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type ChatRequest struct {
	Model    string        `json:"model"`
	Messages []ChatMessage `json:"messages"`
}

type ChatResponse struct {
	Choices []struct {
		Message ChatMessage `json:"message"`
	} `json:"choices"`
}

func AddConfig() {
	readerKey := bufio.NewReader(os.Stdin)
	readerModel := bufio.NewReader(os.Stdin)
	readerURL := bufio.NewReader(os.Stdin)
	var key string
	var model string
	var baseURL string
	for {
		fmt.Print("请输入APIkey: ")
		key, _ = readerKey.ReadString('\n')
		key = strings.TrimSpace(key)
		if key == "" {
			fmt.Println("❌ API-Key不能为空，重新输入")
			continue
		}
		if !strings.HasPrefix(key, "sk-") {
			fmt.Println("❌ API-Key格式错误，必须以 sk- 开头")
			continue
		}
		if len(key) < 20 {
			fmt.Println("❌ API-Key长度太短，至少20个字符")
			continue
		}
		break
	}
	for {
		fmt.Print("请输入Model: ")
		model, _ = readerModel.ReadString('\n')
		model = strings.TrimSpace(model)
		if model == "" {
			fmt.Println("❌ Model不能为空，重新输入")
		}
		if strings.Contains(model, " ") {
			fmt.Println("❌ Model不能包含空格")
			continue
		}
		break
	}
	for {
		fmt.Print("请输入base_url: ")
		baseURL, _ = readerURL.ReadString('\n')
		baseURL = strings.TrimSpace(baseURL)
		if baseURL == "" {
			fmt.Println("❌ URL不能为空，重新输入")
		}
		if !strings.HasPrefix(baseURL, "http://") && !strings.HasPrefix(baseURL, "https://") {
			fmt.Println("❌ URL格式错误，必须以 http:// 或 https:// 开头")
			continue
		}
		break
	}
	cfg := config{
		APIkey:  key,
		Model:   model,
		BaseURL: baseURL,
	}
	jsonData, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		fmt.Println("JSON转换失败:", err)
		return
	}

	err = os.WriteFile("config.json", jsonData, 0600)
	if err != nil {
		fmt.Println("保存失败:", err)
		return
	}

	fmt.Println("✅ 存储成功")
} //添加大模型数据
func editconf() {
	if _, err := os.Stat("config.json"); os.IsNotExist(err) {
		fmt.Println("config file not exist")
		AddConfig()
		return
	}
	data, err := os.ReadFile("config.json")
	if err != nil {
		fmt.Println("读取配置失败:", err)
		return
	}
	fmt.Println(string(data)) ///这里API是显式，后续要修改，为了简单先这样
	fmt.Println("Are you sure you want to edit config? [y/N]")
	reader := bufio.NewReader(os.Stdin)
	answer, _ := reader.ReadString('\n')
	answer = strings.TrimSpace(strings.ToLower(answer))
	if answer == "y" || answer == "yes" {
		AddConfig()
	} else {
		fmt.Println("Cancelled")
		return
	}
}
func loadConfig() (*config, error) {
	data, err := os.ReadFile("config.json")
	if err != nil {
		return nil, err
	}
	var cfg config
	err = json.Unmarshal(data, &cfg)
	if err != nil {
		return nil, err
	}
	return &cfg, nil
}
func runfile(FilePath string) {
	data, err := os.ReadFile(FilePath)
	if err != nil {
		fmt.Println("Faild to read log file:", err)
		return
	}
	cfg, err := loadConfig()
	if err != nil {
		fmt.Println("Faild to load config file:", err)
		return
	}
	//构造请求
	reqBody := ChatRequest{
		Model: cfg.Model,
		Messages: []ChatMessage{
			{Role: "system", Content: "你是一个日志分析助手。请始终用中文回复。如果日志中没有错误，就解释日志内容。如果日志中有错误或异常，请分析原因并给出解决方案。"},
			{Role: "user", Content: string(data)},
		},
	}
	jsonBody, _ := json.Marshal(reqBody) //没有错误返回
	//发送Http请求
	apiURL := strings.TrimRight(cfg.BaseURL, "/") + "/v1/chat/completions"
	req, _ := http.NewRequest("POST", apiURL, strings.NewReader(string(jsonBody))) //没有错误检查
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+cfg.APIkey)

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Println("API request failed:", err)
		return
	}
	defer resp.Body.Close()

	// 解析响应
	body, _ := io.ReadAll(resp.Body) //没错误检查
	var chatResp ChatResponse
	json.Unmarshal(body, &chatResp) //没错误检查

	// 输出结果
	if len(chatResp.Choices) > 0 {
		fmt.Println(chatResp.Choices[0].Message.Content)
	} else {
		fmt.Println("No response from API")
	}
}
func main() {
	var HelpFile bool
	var configFile bool
	var FilePath string

	flag.BoolVar(&HelpFile, "h", false, "Use -h for help")
	flag.BoolVar(&configFile, "c", false, "Use -c  edit config file")
	flag.StringVar(&FilePath, "f", "", "Use -f [FilePath]")
	flag.Parse()
	if _, err := os.Stat("config.json"); os.IsNotExist(err) {
		fmt.Println("初始化配置")
		AddConfig()
		fmt.Println("请重新运行程序")
		return
	}
	if configFile {
		editconf()
		return
	}
	if HelpFile {
		helpfile()
		return
	}
	if FilePath == "" {
		fmt.Println("Usage: ailog <command> [arguments]")
		fmt.Println("Use -f [FilePath] for use this tools")
		fmt.Println("-c --config Setting config file")
		fmt.Println("-h --help for show help")
		return
	}
	runfile(FilePath)
	//合规启动

}
