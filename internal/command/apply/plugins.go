// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package apply

import (
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/anttikivi/reginald/internal/config"
	"github.com/anttikivi/reginald/internal/plugins"
	"github.com/anttikivi/reginald/pkg/task"
)

type checkResult struct {
	name string
	ok   bool
	err  error
}

var (
	errNoPlugins           = errors.New("no plugins provided")
	errInvalidPluginConfig = errors.New("invalid plugin config")
)

func checkPluginConfigs(cfg *config.Config) (bool, error) {
	if len(cfg.PluginInfos) == 0 {
		return true, fmt.Errorf("%w", errNoPlugins)
	}

	var (
		infos    = cfg.PluginInfos
		resultCh = make(chan checkResult)
		wg       sync.WaitGroup
	)

	for _, info := range infos {
		wg.Add(1)

		go func() {
			defer wg.Done()

			ok, err := runCheck(info, cfg.Tasks)
			resultCh <- checkResult{
				name: info.Name,
				ok:   ok,
				err:  err,
			}
		}()
	}

	go func() {
		wg.Wait()
		close(resultCh)
	}()

	for r := range resultCh {
		if r.err != nil {
			return false, fmt.Errorf("failed to check the plugin configs: %w", r.err)
		}

		if !r.ok {
			return false, fmt.Errorf("%w: %s", errInvalidPluginConfig, r.name)
		}
	}

	time.Sleep(time.Second * 5)

	return true, nil
}

func runCheck(info plugins.PluginInfo, cfgs []task.Config) (bool, error) {
	client, err := plugins.NewClient(info)
	if err != nil {
		return false, fmt.Errorf("%w", err)
	}
	defer client.Kill()

	rpcClient, err := client.Client()
	if err != nil {
		log.Fatal(err)
	}

	for _, t := range cfgs {
		if _, ok := info.Tasks[t.Type]; !ok {
			continue
		}

		raw, err := rpcClient.Dispense("task-" + t.Type)
		if err != nil {
			log.Fatal(err)
		}

		task := raw.(task.Task)
		fmt.Println(task.Check(&t))
	}

	return true, nil
}
