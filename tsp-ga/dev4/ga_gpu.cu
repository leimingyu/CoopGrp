#include <iostream>
#include <algorithm>
#include <functional> // for bind()
#include <ctime> // clock

// Program includes
#include "ga_gpu.h"
#include "common.h"

#include <curand.h>
#include <curand_kernel.h>


using namespace std;
namespace cg = cooperative_groups;

__device__ int getGlobalIdx_2D_1D()
{
	int blockId  = blockIdx.y * gridDim.x + blockIdx.x;			 	
	int threadId = blockId * blockDim.x + threadIdx.x; 
	return threadId;
}


bool checkForKernelError(const char *err_msg)
{
	cudaError_t status = cudaGetLastError();
	if (status != cudaSuccess)
	{
		cout << err_msg << cudaGetErrorString(status) << endl;
		return true;
	}
	else
	{
		return false;
	}
}

__device__ void crossover(World* old_pop, World* new_pop, int* sel_ix,  int* cross_loc, int tid)
{

	// Copy elements from first parent up through crossover point
	memcpy(new_pop[tid].cities, old_pop[sel_ix[2*tid]].cities,(cross_loc[tid] + 1) * sizeof(City));

	// Add remaining elements from second parent to child, in order
	int remaining = old_pop[tid].num_cities - cross_loc[tid] - 1;
	int count     = 0;
	for (int i=0; i<old_pop[tid].num_cities; i++)
	{
		bool in_child = false;
		for (int j=0; j<=cross_loc[tid]; j++)     
		{
			// If the city is in the child, exit
			if ((new_pop[tid].cities[j].x == old_pop[sel_ix[2 * tid + 1]].cities[i].x) &               
					(new_pop[tid].cities[j].y == old_pop[sel_ix[2 * tid + 1]].cities[i].y))
			{
				in_child = true;
				break;
			}
		}
		if (!in_child)
		{
			count++;
			memcpy(&new_pop[tid].cities[cross_loc[tid] + count],&old_pop[sel_ix[2 * tid + 1]].cities[i], sizeof(City));
		}

		// Stop once all of the cities have been added
		if (count == remaining) break;
	}
}

__device__ void mutate(World* new_pop, int* mutate_loc, int tid)
{
	// Swap the elements
	City temp = *(new_pop[tid].cities + mutate_loc[2*tid]);
	*(new_pop[tid].cities + mutate_loc[2*tid])   = *(new_pop[tid].cities + mutate_loc[2*tid+1]);
	*(new_pop[tid].cities + mutate_loc[2*tid+1]) = temp;
}



extern "C" __global__ void fitness_kernel(World* pop, int pop_size, float *fit_sum)
{
	//int tid = getGlobalIdx_2D_1D();
	//if (tid < pop_size)
	//{
	//	float distance = 0.f; // Total "normalized" "distance"
	//	int city_num = pop[tid].num_cities - 1;
	//	for (int i=0; i<city_num; i++) {
	//		float loc_x = pop[tid].cities[i].x - pop[tid].cities[i + 1].x;
	//		float loc_y = pop[tid].cities[i].y - pop[tid].cities[i + 1].y;
	//		distance += loc_x * loc_x + loc_y * loc_y;
	//	}
	//	pop[tid].fitness = (pop[tid].width * pop[tid].height) / distance;
	//}



	cg::grid_group grid = cg::this_grid();
	int tid = grid.thread_rank();

	//for (int tid = grid.thread_rank(); tid < pop_size; tid += grid.size()) {
	if (tid < pop_size) {
		float distance = 0.f; // Total "normalized" "distance"
		int city_num = pop[tid].num_cities - 1;
		for (int i=0; i<city_num; i++) {
			float loc_x = pop[tid].cities[i].x - pop[tid].cities[i + 1].x;
			float loc_y = pop[tid].cities[i].y - pop[tid].cities[i + 1].y;
			distance += loc_x * loc_x + loc_y * loc_y;
		}

		pop[tid].fitness = (pop[tid].width * pop[tid].height) / distance;
	}

	cg::sync(grid);

	//for (int tid = grid.thread_rank(); tid < pop_size; tid += grid.size()) {
	if (tid < pop_size) {
		float sum = 0.f;
		for (int i=0; i<=tid; i++)
			sum += pop[i].fitness;
		pop[tid].fit_prob = sum;
		if (tid == (pop_size - 1)) {
			*fit_sum = sum;
		}
	}

	cg::sync(grid);

	if (tid < pop_size) {
		pop[tid].fit_prob /= *fit_sum;
	}
}


//
// NOTE: use cooperative groups to merge two kernels togather :  fit_sum_kernel + fit_prob_kernel 
//


__global__ void max_fit_kernel(World* pop, int pop_size, World* gen_leader)
{
	// Get the thread id
	int tid = getGlobalIdx_2D_1D();

	// Evaluate if the thread is valid
	if (tid < pop_size)
	{
		if (tid == 0)
		{
			float max = (float)0.0;
			int ix  = 0;
			for (int i=1; i<pop_size; i++)
			{
				if (pop[i].fitness > max)
				{
					max = pop[i].fitness;
					ix  = i;
				}
			}
			gen_leader->cities  = pop[ix].cities;
			gen_leader->fitness = max;
		}
		else if (tid == 1)
		{
			gen_leader->height     = pop[0].height;
			gen_leader->width      = pop[0].width;
			gen_leader->num_cities = pop[0].num_cities;
		}
	}
}


/*
extern "C" __global__ void selection_kernel(World* pop, int pop_size, float* rand_nums, int* sel_ix)
{

	cg::grid_group grid = cg::this_grid();
	int tid = grid.thread_rank();
	int TwicePopSize = pop_size + pop_size;

	for (int tid = grid.thread_rank(); tid < TwicePopSize; tid += grid.size()) {
		// Select the parents
		for (int j=0; j<pop_size; j++)
		{
			if (rand_nums[tid] <= pop[j].fit_prob)
			{
				sel_ix[tid] = j;
				break;
			}
		}
	}
}
*/

extern "C" __global__ void selection_child_kernel(World* old_pop, int pop_size, float* rand_nums, int* sel_ix,
		World *new_pop, float prob_crossover, float *prob_cross, int *cross_loc, 
		float prob_mutation, float *prob_mutate, int *mutate_loc)
{

	cg::grid_group grid = cg::this_grid();
	int tid = grid.thread_rank();
	int TwicePopSize = pop_size + pop_size;

	for (int tid = grid.thread_rank(); tid < TwicePopSize; tid += grid.size()) {
		// Select the parents
		for (int j=0; j<pop_size; j++)
		{
			if (rand_nums[tid] <= old_pop[j].fit_prob)
			{
				sel_ix[tid] = j;
				break;
			}
		}
	}

	cg::sync(grid);

	for (int tid = grid.thread_rank(); tid < pop_size; tid += grid.size()) {
		// Determine how many children are born
		if (prob_cross[tid] <= prob_crossover)
		{
			crossover(old_pop, new_pop, sel_ix, cross_loc, tid);
			if(prob_mutate[tid] <= prob_mutation) mutate(new_pop, mutate_loc, tid);
		}
		else // Select the first parent
		{
			// Add child to new population
			memcpy(new_pop[tid].cities, old_pop[sel_ix[2*tid]].cities, old_pop[tid].num_cities * sizeof(City));
			if(prob_mutate[tid] <= prob_mutation) mutate(new_pop, mutate_loc, tid);
		}
	}

}


__global__ void child_kernel(World* old_pop, World* new_pop, int pop_size,    \
		int* sel_ix, float prob_crossover, float* prob_cross, int* cross_loc,     \
		float prob_mutation, float* prob_mutate, int* mutate_loc)
{
	// Get the thread id
	int tid = getGlobalIdx_2D_1D();

	// Evaluate if the thread is valid
	if (tid < pop_size)
	{
		// Determine how many children are born
		if (prob_cross[tid] <= prob_crossover)
		{
			crossover(old_pop, new_pop, sel_ix, cross_loc, tid);
			if(prob_mutate[tid] <= prob_mutation)
				mutate(new_pop, mutate_loc, tid);

		}
		else // Select the first parent
		{
			// Add child to new population
			memcpy(new_pop[tid].cities, old_pop[sel_ix[2*tid]].cities, old_pop[tid].num_cities * sizeof(City));
			if(prob_mutate[tid] <= prob_mutation)
				mutate(new_pop, mutate_loc, tid);
		}
	}
}

/*
__global__ void setup_kernel ( curandState * state, unsigned int seed, int N)
{
	unsigned int tid = blockIdx.x * blockDim.x + threadIdx.x;
	if (tid < N)
		curand_init( seed, tid, 0, &state[tid] );
} 
*/




__global__ void genProb(const int pop_size ,const int seed, float* prob_select, 
		float* prob_cross, 
		float* prob_mutate,
		int* cross_loc,
		int* mutate_loc,
		const int num_cities)
{
	uint gid = threadIdx.x + blockIdx.x * blockDim.x;	

	if (gid < pop_size)
	{
		curandState state;
		curand_init(seed, gid, 0, &state);

		prob_select[gid + gid]     = curand_uniform(&state);
		prob_select[gid + gid + 1] = curand_uniform(&state);

		prob_cross[gid] = curand_uniform(&state);

		prob_mutate[gid] = curand_uniform(&state);

		cross_loc[gid]  = (int)(curand_uniform(&state) * (num_cities - 1));


		int mutate_1 = (int)(curand_uniform(&state) * num_cities);
		int mutate_2 = (int)(curand_uniform(&state) * num_cities);

		while (mutate_2 == mutate_1)
		{
			mutate_2 = (int)(curand_uniform(&state) * num_cities);
		}

		mutate_loc[gid + gid]      = mutate_1;
		mutate_loc[gid + gid + 1]  = mutate_2;
	}

}



bool g_initialize(World* world, World* pop_d, int pop_size, int seed)
{
	bool error;
	World h_world;
	h_world.cities = new City[world->num_cities * sizeof(City)];
	srand(seed);
	for (int i=0; i<pop_size; i++)
	{
		clone_world(world, &h_world);
		// Randomly adjust the path between cities
		random_shuffle(&h_world.cities[0], &h_world.cities[world->num_cities]);

		// Copy world to device
		error = g_soft_clone_world(&pop_d[i], &h_world);
		if (error)
			return true;

		// Allocate space for cities on device
		City *d_city;
		error = checkForError(cudaMalloc((void**)&d_city, world->num_cities * sizeof(City)));
		if (error)
			return true;

		// Copy cities to device
		error = checkForError(cudaMemcpy(d_city, h_world.cities,world->num_cities * sizeof(City), cudaMemcpyHostToDevice));
		if (error)
			return true;

		// Update pointer on device
		error = checkForError(cudaMemcpy(&pop_d[i].cities, &d_city, sizeof(City*), cudaMemcpyHostToDevice));
		if (error)
			return true;
	}

	// Success
	delete[] h_world.cities; return false;
}


bool g_evaluate(World *pop, int pop_size, dim3 Block, dim3 Grid, int blk_size, int grid_size, int numSms)
{
	int numBlocksPerSm = 0;
	checkCudaErrors(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&numBlocksPerSm, 
				fitness_kernel, THREADS_PER_BLOCK, 0));
	//printf("numBlocksPerSm: %d\n", numBlocksPerSm);


	// NOTE: 80 sms x 4 max blocks (for 512 as the block size)
	dim3 dimGrid(numSms*numBlocksPerSm, 1, 1), dimBlock(THREADS_PER_BLOCK, 1, 1);



	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	bool error;

	// Allocate fitness sum on the GPU
	float *fit_sum_d;
	error = checkForError(cudaMalloc((void**)&fit_sum_d, sizeof(float)));
	if (error) return true;

	void *kernelArgs[] = {
		(void*)&pop,
		(void*)&pop_size,
		(void*)&fit_sum_d,
	};

	cudaEventRecord(start);

	checkCudaErrors(cudaLaunchCooperativeKernel((void *)fitness_kernel, dimGrid, dimBlock, kernelArgs, 0, NULL));

	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	float timer_ms = 0.f;
	cudaEventElapsedTime(&timer_ms, start, stop);
	printf("[Timing] \t\t g_evaluate : %f (ms)\n", timer_ms);

	cudaFree(fit_sum_d); 
	return false;
}



int g_select_leader(World* pop, int pop_size, World* generation_leader,
		World* best_leader, dim3 Block, dim3 Grid)
{
	// Error handling
	bool error;

	// Initialize world for device generation leader
	World *gen_leader_d;
	error = checkForError(cudaMalloc((void**)&gen_leader_d, sizeof(World)));
	if (error) return -1;


	// Purposely don't allocate space for the cities, simply use a pointer.
	// Since we only need to copy data to cpu 
	error = g_soft_clone_world(gen_leader_d, generation_leader);
	if (error) return -1;

	// Calculate the max fitness
	max_fit_kernel <<< Grid, Block >>> (pop, pop_size, gen_leader_d);

	//cudaDeviceSynchronize();
	if (checkForKernelError("*** Max fitness kernel failed: ")) return -1;

	// Copy results from device
	City *h_ptr = generation_leader->cities;
	City *d_ptr;
	error = checkForError(cudaMemcpy(generation_leader, gen_leader_d, sizeof(World), cudaMemcpyDeviceToHost));
	if (error) return -1;

	d_ptr = generation_leader->cities;
	generation_leader->cities = h_ptr;
	error = checkForError(cudaMemcpy(generation_leader->cities,  d_ptr, generation_leader->num_cities * sizeof(City), cudaMemcpyDeviceToHost));
	if (error) return -1;

	// Update best leader
	if (generation_leader->fitness > best_leader->fitness)
	{
		clone_world(generation_leader, best_leader);
		cudaFree(gen_leader_d); return 1;
	}

	// Success
	cudaFree(gen_leader_d);	return 0;
}

bool g_execute(float prob_mutation, float prob_crossover, int pop_size, int max_gen, World* world, int seed, 
		int blk_size, int grid_size, int pop_bytes, int numSms)
{
	//=================================//
	// Cooperative Kernel Configuration 
	//=================================//
	int numBlocksPerSm = 0;
	checkCudaErrors(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&numBlocksPerSm, 
				selection_child_kernel, THREADS_PER_BLOCK, 0));
	printf("numBlocksPerSm: %d\n", numBlocksPerSm);
	dim3 dimGrid(numSms*numBlocksPerSm, 1, 1), dimBlock(THREADS_PER_BLOCK, 1, 1);

	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	float timer_ms = 0.f;
	

	// Error checking variables
	bool error;

	// Random number generation
	mt19937::result_type rseed = seed;
	auto rgen = bind(uniform_real_distribution<>(0, 1), mt19937(rseed));
	// __device__ float curand_uniform ( curandStateMtgp32_t* state )

	dim3 Block(blk_size);
	dim3 Grid(grid_size, grid_size);

	World *old_pop_d, *new_pop_d;

	// Random numbers
	float *prob_select = new float[2 * pop_size * sizeof(float)];
	float *prob_cross  = new float[pop_size * sizeof(float)];
	float *prob_mutate = new float[pop_size * sizeof(float)];
	int   *cross_loc   = new int[pop_size * sizeof(int)];
	int   *mutate_loc  = new int[2 * pop_size * sizeof(int)];
	float *prob_select_d, *prob_cross_d, *prob_mutate_d;
	int   *cross_loc_d, *mutate_loc_d;

	int   sel;
	int   best_generation    = 0;
	World *best_leader       = new World[sizeof(World)];
	World *generation_leader = new World[sizeof(World)];

	// Other "temporary" parameters
	int *sel_ix_d;

	//Initializations
	init_world(best_leader, world->width, world->height, world->num_cities);
	init_world(generation_leader, world->width, world->height, world->num_cities);

	if (checkForError(cudaMalloc((void**) &old_pop_d, pop_bytes)))
		return true;
	if (checkForError(cudaMalloc((void**) &new_pop_d, pop_bytes)))
		return true;
	if (checkForError(cudaMalloc((void**) &prob_select_d, sizeof(float)* 2 * pop_size)))
		return true;
	if (checkForError(cudaMalloc((void**) &prob_cross_d, sizeof(float) * pop_size)))
		return true;
	if (checkForError(cudaMalloc((void**) &prob_mutate_d, sizeof(float) * pop_size)))
		return true;
	if (checkForError(cudaMalloc((void**) &cross_loc_d, sizeof(int) * pop_size)))
		return true;
	if (checkForError(cudaMalloc((void**) &mutate_loc_d, sizeof(int) * 2 * pop_size)))
		return true;
	// Other parameters
	if (checkForError(cudaMalloc((void**) &sel_ix_d, sizeof(int) * 2 * pop_size)))
		return true;

	///////// GPU Initializations
	// Populations
	error = g_initialize(world, old_pop_d, pop_size, seed);
	if (error) return true;

	for (int i=0; i<pop_size; i++)
	{
		error = g_init_world(&new_pop_d[i], world);
		if (error)
			return true;
	}


	// Calculate the fitnesses
	error = g_evaluate(old_pop_d, pop_size, Block, Grid, blk_size, grid_size, numSms);
	if (error) return true;

	// Initialize the best leader
	sel = g_select_leader(old_pop_d, pop_size, generation_leader, best_leader, Block, Grid);	
	if (-1 == sel) return true;	


	print_status(generation_leader, best_leader, 0);



	void *kernelArgs[] = {
		(void*)&old_pop_d,
		(void*)&pop_size,
		(void*)&prob_select_d,
		(void*)&sel_ix_d,
		(void*)&new_pop_d, // below are for child kernel
		(void*)&prob_crossover,
		(void*)&prob_cross_d,
		(void*)&cross_loc_d,
		(void*)&prob_mutation,
		(void*)&prob_mutate_d,
		(void*)&mutate_loc_d,
	};


	//curandState* devStates;
	//cudaMallocManaged((void**)&devStates, pop_size * sizeof(curandState));
	//setup_kernel <<< (pop_size + 1023) / 1024,1024 >>> (devStates, seed, pop_size);





	cout << "pop_size : " << pop_size << endl;

	// Continue through all generations
	for (int i=0; i<max_gen; i++)
	{

		// Generate all probabilities for each step
		// Note : The order the random numbers are generated must be consistent to
		// ensure the results will match the CPU.


		/*
		clock_t begin = clock();

		for (int j=0; j<pop_size; j++)
		{
			prob_select[2*j]     = (float)rgen();

			//cout << prob_select[2*j]  << endl;
			//if (j == 2) break;

			prob_select[2*j + 1] = (float)rgen();
			prob_cross[j]        = (float)rgen();
			cross_loc[j]         = (int)(rgen() * (world->num_cities - 1));
			prob_mutate[j]       = (float)rgen();
			mutate_loc[2*j]      = (int)(rgen() * (world->num_cities));
			mutate_loc[2*j + 1]  = (int)(rgen() * (world->num_cities));
			while (mutate_loc[2*j + 1] == mutate_loc[2*j])
			{
				mutate_loc[2*j + 1] = (int)(rgen() * world->num_cities);
			}
		}

		// Copy random numbers to device
		if (checkForError(cudaMemcpy(prob_select_d, prob_select, 2 * pop_size * sizeof(float), cudaMemcpyHostToDevice)))
			return true;
		if (checkForError(cudaMemcpy(prob_cross_d, prob_cross, pop_size * sizeof(float), cudaMemcpyHostToDevice)))
			return true;
		if (checkForError(cudaMemcpy(prob_mutate_d, prob_mutate,pop_size * sizeof(float), cudaMemcpyHostToDevice)))
			return true;
		if (checkForError(cudaMemcpy(cross_loc_d, cross_loc,pop_size * sizeof(int), cudaMemcpyHostToDevice)))
			return true;
		if (checkForError(cudaMemcpy(mutate_loc_d, mutate_loc, 2 * pop_size * sizeof(int), cudaMemcpyHostToDevice)))
			return true;


		clock_t end = clock();
		double elapsed_secs = double(end - begin) / CLOCKS_PER_SEC;
		cout << "[Timing] genProb (default) = " << elapsed_secs << "(s)" << endl;
		*/


		//-----------//
		// rand using gpu kernel
		//-----------//
		cudaEventRecord(start);

		//setup_kernel <<< (pop_size + 1023) / 1024,1024 >>> (devStates, seed, pop_size);

		genProb <<< (pop_size + 1023) / 1024,1024 >>> (pop_size, seed, 
				prob_select_d, prob_cross_d, prob_mutate_d, cross_loc_d, mutate_loc_d, world->num_cities);

		//cudaEventRecord(stop);
		//cudaEventSynchronize(stop);
		//timer_ms = 0.f;
		//cudaEventElapsedTime(&timer_ms, start, stop);
		//printf("[Timing] \t\t randProb: %f (ms)\n", timer_ms);





		//cudaEventRecord(start);

		// Select the parents
		//checkCudaErrors(cudaLaunchCooperativeKernel((void *)selection_kernel, dimGrid, dimBlock, kernelArgs, 0, NULL));
		checkCudaErrors(cudaLaunchCooperativeKernel((void *)selection_child_kernel, dimGrid, dimBlock, kernelArgs, 0, NULL));


		cudaEventRecord(stop);
		cudaEventSynchronize(stop);
		timer_ms = 0.f;
		cudaEventElapsedTime(&timer_ms, start, stop);
		printf("[Timing] \t\t rand_selection_child : %f (ms)\n", timer_ms);

		// Calculate the fitnesses on the new population
		error = g_evaluate(new_pop_d, pop_size, Block, Grid, blk_size, grid_size, numSms);
		if (error) return true;	

		// Swap the populations
		World* temp_d = old_pop_d;
		old_pop_d     = new_pop_d;
		new_pop_d     = temp_d;

		// Select the new leaders
		sel = g_select_leader(old_pop_d, pop_size, generation_leader,best_leader, Block, Grid);
		if (-1 == sel)
			return true;
		else if (1 == sel) best_generation = i + 1;
		print_status(generation_leader, best_leader, i + 1);
	} 

	cout << endl << "Best generation found at " << best_generation << " generations" << endl;

	//freeing memory
	delete[] prob_select; delete[] prob_cross; delete[] prob_mutate;
	delete[] cross_loc; delete[] mutate_loc; free_world(best_leader);
	free_world(generation_leader); cudaFree(old_pop_d); cudaFree(cross_loc_d); 
	cudaFree(new_pop_d); cudaFree(prob_select_d); cudaFree(prob_cross_d);
	cudaFree(prob_mutate_d); cudaFree(mutate_loc_d); cudaFree(sel_ix_d);	

	//cudaFree(devStates);


	return false;
}
